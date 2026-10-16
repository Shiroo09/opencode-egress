// egress-rotate — OpenCode plugin. When the free-tier bucket of the current
// egress IP is spent, rotate the local router to the next VPS and re-send the
// last user message with the SAME model, so the open chat continues where it
// stopped instead of waiting ~24h.
//
// Detection: `session.status` events of type "retry" whose message matches a
// rate-limit pattern (same signal the TUI shows as "Free usage exceeded").
// Rotation itself is a localhost HTTP call to egress-router.mjs, which keeps
// serving 127.0.0.1:8888 while its upstream changes. OpenCode never restarts.
//
// If every egress in the pool is exhausted the plugin does nothing and lets
// OpenCode retry normally.

import type { Hooks, PluginInput } from "@opencode-ai/plugin";
import { loadConfig } from "./config.ts";
import { createLogger } from "./log.ts";

interface RetryStatus {
  type: "idle" | "retry" | "busy";
  attempt?: number;
  message?: string;
  next?: number;
}

interface MessageInfo {
  id: string;
  role: "user" | "assistant";
  sessionID: string;
  model?: { providerID: string; modelID: string };
  agent?: string;
}

interface MessagePart {
  id: string;
  type: string;
  text?: string;
  mime?: string;
  filename?: string;
  url?: string;
  name?: string;
}

interface MessageWithParts {
  info: MessageInfo;
  parts: MessagePart[];
}

// Guards one rotation per session at a time; retry events fire repeatedly
// while the failed attempt is being torn down.
const rotating = new Set<string>();
const lastRotation = new Map<string, number>();
const ROTATE_GUARD_MS = 15000;

function matches(patterns: string[], message: string): boolean {
  const lower = message.toLowerCase();
  return patterns.some((p) => lower.includes(p.toLowerCase()));
}

async function routerPost(routerUrl: string, path: string, body: unknown): Promise<{ status: number; data: any }> {
  const res = await fetch(`${routerUrl}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });
  let data: any = null;
  try {
    data = await res.json();
  } catch {
    // plain-text body, ignore
  }
  return { status: res.status, data };
}

export async function createPlugin(context: PluginInput): Promise<Hooks> {
  const config = await loadConfig();
  const logger = createLogger(config.logging);
  await logger.info("egress-rotate initialized", {
    enabled: config.enabled,
    routerUrl: config.routerUrl,
    cooldownMs: config.cooldownMs,
  });
  if (!config.enabled) return {};

  return {
    event: async ({ event }) => {
      if (event.type === "session.deleted") {
        const id = (event.properties as { info?: { id?: string } })?.info?.id;
        if (id) {
          rotating.delete(id);
          lastRotation.delete(id);
        }
        return;
      }
      if (event.type !== "session.status") return;
      const props = event.properties as { sessionID: string; status: RetryStatus };
      if (props.status.type === "idle") return;
      if (props.status.type !== "retry" || !props.status.message) return;
      if (!matches(config.patterns, props.status.message)) return;

      const sessionID = props.sessionID;
      const now = Date.now();
      if (rotating.has(sessionID)) return;
      if (now - (lastRotation.get(sessionID) ?? 0) < ROTATE_GUARD_MS) {
        await logger.info("rotation guard: skip duplicate retry event", { sessionID });
        return;
      }
      rotating.add(sessionID);
      try {
        await logger.info("rate limit detected, rotating egress", {
          sessionID,
          message: props.status.message.slice(0, 200),
        });

        // Read which egress just got spent, so the mark lands on it even if
        // the router already moved on.
        let spent: string | null = null;
        try {
          const res = await fetch(`${config.routerUrl}/status`);
          if (res.ok) spent = ((await res.json()) as { active: string }).active ?? null;
        } catch (err) {
          await logger.error("router /status unreachable", { error: String(err) });
          return;
        }
        if (spent) {
          await routerPost(config.routerUrl, "/exhausted", { name: spent, cooldownMs: config.cooldownMs });
        }
        const next = await routerPost(config.routerUrl, "/next", {});
        if (next.status === 409) {
          await logger.info("all egresses exhausted, keep normal retry", { sessionID });
          return;
        }
        if (next.status !== 200) {
          await logger.error("router /next failed", { status: next.status, data: next.data });
          return;
        }
        lastRotation.set(sessionID, Date.now());
        await logger.info("rotated egress", { from: spent, to: (next.data as { active: string })?.active });

        try {
          await context.client.session.abort({ path: { id: sessionID } });
          await new Promise((r) => setTimeout(r, 200));

          const messagesResponse = await context.client.session.messages({ path: { id: sessionID } });
          const messages = messagesResponse.data as MessageWithParts[] | undefined;
          const lastUser = messages ? [...messages].reverse().find((m) => m.info.role === "user") : undefined;
          if (!lastUser) {
            await logger.error("no user message to re-send", { sessionID });
            return;
          }
          await context.client.session.revert({
            path: { id: sessionID },
            body: { messageID: lastUser.info.id },
          });
          await new Promise((r) => setTimeout(r, 500));

          const parts = lastUser.parts
            .filter((p) => !(p as unknown as { synthetic?: boolean }).synthetic)
            .map(convertToPromptPart)
            .filter((p): p is NonNullable<typeof p> => p !== null);
          if (parts.length === 0) {
            await logger.error("no re-sendable parts in user message", { sessionID });
            return;
          }
          // Same model, new egress IP. If the message carried no explicit
          // model, omit it and let the session default apply.
          await context.client.session.prompt({
            path: { id: sessionID },
            body: {
              ...(lastUser.info.model ? { model: lastUser.info.model } : {}),
              ...(lastUser.info.agent ? { agent: lastUser.info.agent } : {}),
              parts,
            },
          });
          await logger.info("message re-sent via new egress", { sessionID });
        } catch (err) {
          // Rotation already happened, so even a failed re-send leaves the
          // user one manual retry away from the fresh bucket.
          await logger.error("re-send failed, egress already rotated", {
            sessionID,
            error: err instanceof Error ? err.message : String(err),
          });
        }
      } finally {
        rotating.delete(sessionID);
      }
    },
  };
}

function convertToPromptPart(
  part: MessagePart
):
  | { type: "text"; text: string }
  | { type: "file"; mime: string; filename?: string; url: string }
  | { type: "agent"; name: string }
  | null {
  switch (part.type) {
    case "text":
      return part.text ? { type: "text", text: part.text } : null;
    case "file":
      return part.url && part.mime ? { type: "file", mime: part.mime, filename: part.filename, url: part.url } : null;
    case "agent":
      return part.name ? { type: "agent", name: part.name } : null;
    default:
      return null;
  }
}

export default createPlugin;
