export interface EgressRotateConfig {
  enabled: boolean;
  routerUrl: string;
  cooldownMs: number;
  patterns: string[];
  logging: boolean;
}

const DEFAULT_PATTERNS = [
  "freeusagelimit",
  "free usage exceeded",
  "rate limit exceeded",
  "rate limit",
  "usage limit",
  "too many requests",
  "quota exceeded",
  "retrying in",
  "429",
  "overloaded",
  "capacity exceeded",
];

const CANDIDATE_PATHS = [
  "rate-limit-fallback.json",
  "egress-rotate.json",
  "config/rate-limit-fallback.json",
  "config/egress-rotate.json",
  "plugins/rate-limit-fallback.json",
  "plugins/egress-rotate.json",
  "plugin/rate-limit-fallback.json",
  "plugin/egress-rotate.json",
];

function configDir(): string {
  const home = process.env.HOME || process.env.USERPROFILE || "";
  // HOME on Git Bash already points at the Windows profile.
  return `${home}/.config/opencode`;
}

async function readJson(file: string): Promise<Record<string, unknown> | null> {
  try {
    const { readFile } = await import("node:fs/promises");
    return JSON.parse(await readFile(file, "utf8"));
  } catch {
    return null;
  }
}

export async function loadConfig(): Promise<EgressRotateConfig> {
  const base = configDir();
  for (const rel of CANDIDATE_PATHS) {
    const found = await readJson(`${base}/${rel}`);
    if (found) return normalize(found);
  }
  return normalize({});
}

function normalize(raw: Record<string, unknown>): EgressRotateConfig {
  return {
    enabled: raw.enabled !== false,
    routerUrl:
      typeof raw.routerUrl === "string" && raw.routerUrl
        ? raw.routerUrl
        : typeof raw.router === "string" && raw.router
          ? raw.router
          : "http://127.0.0.1:8899",
    cooldownMs:
      typeof raw.cooldownMs === "number" && raw.cooldownMs > 0
        ? raw.cooldownMs
        : 24 * 60 * 60 * 1000,
    patterns: Array.isArray(raw.patterns) && raw.patterns.length > 0 ? raw.patterns.map(String) : DEFAULT_PATTERNS,
    logging: raw.logging === true,
  };
}
