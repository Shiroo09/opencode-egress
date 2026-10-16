export interface Logger {
  info(message: string, extra?: unknown): Promise<void>;
  error(message: string, extra?: unknown): Promise<void>;
}

function logFile(): string {
  const home = process.env.HOME || process.env.USERPROFILE || "";
  return `${home}/.local/share/opencode/logs/egress-rotate.log`;
}

export function createLogger(enabled: boolean): Logger {
  const write = async (level: string, message: string, extra?: unknown) => {
    if (!enabled) return;
    try {
      const { appendFile, mkdir } = await import("node:fs/promises");
      const { dirname } = await import("node:path");
      const file = logFile();
      await mkdir(dirname(file), { recursive: true });
      const line =
        `${new Date().toISOString()} ${level} ${message}` +
        (extra !== undefined ? ` ${JSON.stringify(extra)}` : "") +
        "\n";
      await appendFile(file, line);
    } catch {
      // logging must never break the session
    }
  };
  return {
    info: (message, extra) => write("INFO", message, extra),
    error: (message, extra) => write("ERROR", message, extra),
  };
}
