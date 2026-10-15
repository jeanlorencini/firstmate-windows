import { type ChildProcess, spawn } from "node:child_process";

// Pi runs extensions, their tools, and their event handlers on the single
// JavaScript thread that also draws the TUI and reads the keyboard, and it
// starts no worker for them. A spawnSync call from an extension therefore
// stops repaint and key echo for the child's whole lifetime, which a
// supervision outcome made visible as a subsecond freeze every time one
// arrived (docs/pi-supervision-branch.md "Off-thread delivery").
//
// This is the one owner of that replacement: the status, UTF-8 stdout, and
// UTF-8 stderr fields these callers consumed from spawnSync, produced by an
// awaited spawn so the event loop keeps running while the child does. Callers
// keep their own ordering guarantees - awaiting here
// yields the thread, so anything that must not interleave belongs behind a
// serializing queue in the caller.
//
// Like spawnSync, a spawn that never starts and a child killed by a signal
// both report a null status rather than throwing, so a caller's existing
// "status !== 0" failure branch keeps its meaning unchanged.
//
// Every call is bounded. Each caller awaits it inside a Pi event handler, and
// Pi awaits the handler, so a child that stalls stalls the captain's turn with
// it (a fleet-lease release once held a turn boundary for 79 s). At the
// deadline the child's whole process tree is killed and the call reports a
// null status with a "timed out" stderr, the same failure branch a crash
// takes, so every caller stays fail-closed and retries at its next boundary.
// A killed script may leave a lock owner behind; the lock helpers reclaim an
// owner whose pid is dead, so the next acquirer recovers it.

export interface AsyncExecResult {
  /** Exit code, or null when the child was signalled or never started. */
  status: number | null;
  stdout: string;
  stderr: string;
  /** True only when the deadline killed the child. */
  timedOut: boolean;
}

export interface AsyncExecOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /** Written to the child's stdin, which is closed either way. */
  input?: string;
  /**
   * Upper bound on each captured output stream, mirroring spawnSync's
   * maxBuffer. Defaults to 1 MiB.
   */
  maxBuffer?: number;
  /** Deadline for the whole child process tree. Defaults to 30 s. */
  timeoutMs?: number;
}

const DEFAULT_MAX_BUFFER = 1024 * 1024;
const DEFAULT_TIMEOUT_MS = 30_000;
const isWindows = process.platform === "win32";

// Git Bash's own process table: find the MSYS pid whose Win32 pid is $1,
// collect every descendant through /proc ppid links BEFORE killing anything
// (a dead parent reparents its children to 1), then kill exactly that set.
// Exit 3 when $1 is not an MSYS process. Win32 parent links cannot do this:
// an MSYS exec replaces the Win32 process, so a backgrounded grandchild such
// as `sleep &` has no live Win32 parent and taskkill /T never reaches it.
const MSYS_KILL_TREE = `root=
for p in /proc/[0-9]*; do
  w=; { read -r w < "$p/winpid"; } 2>/dev/null
  [ "$w" = "$1" ] && { root=\${p#/proc/}; break; }
done
[ -n "$root" ] || exit 3
all=$root frontier=$root
while [ -n "$frontier" ]; do
  next=
  for p in /proc/[0-9]*; do
    pp=; { read -r pp < "$p/ppid"; } 2>/dev/null
    for f in $frontier; do [ "$pp" = "$f" ] && next="$next \${p#/proc/}"; done
  done
  all="$all$next" frontier=$next
done
kill -KILL $all 2>/dev/null
exit 0`;

// Kill the child and everything below it, never anything else. Elsewhere the
// child leads its own process group (detached below), so the negative pid
// reaches exactly that group. Callers only ask while the child has not
// exited, and Node holds the child's process handle until its exit is
// processed, so the pid cannot have been reused for an unrelated process; the
// Windows fallback re-checks that before it names the pid to taskkill.
function killTree(child: ChildProcess): void {
  if (child.pid === undefined) return;
  const pid = child.pid;
  const alive = (): boolean => child.exitCode === null && child.signalCode === null;
  try {
    if (!isWindows) {
      process.kill(-pid, "SIGKILL");
      return;
    }
    const taskkill = (): void => {
      if (!alive()) return;
      spawn("taskkill", ["/PID", String(pid), "/T", "/F"], { stdio: "ignore", windowsHide: true }).on("error", () =>
        child.kill(),
      );
    };
    spawn("bash", ["-c", MSYS_KILL_TREE, "fm-kill-tree", String(pid)], { stdio: "ignore", windowsHide: true })
      .on("error", taskkill)
      .on("exit", (code) => {
        if (code !== 0) taskkill();
      });
  } catch {
    child.kill("SIGKILL");
  }
}

export function runCommandAsync(
  command: string,
  args: readonly string[],
  options: AsyncExecOptions = {},
): Promise<AsyncExecResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let stdoutBytes = 0;
    let stderrBytes = 0;
    const maxBuffer = options.maxBuffer ?? DEFAULT_MAX_BUFFER;
    let settled = false;
    let timer: NodeJS.Timeout | undefined;
    const finish = (status: number | null, detail = "", timedOut = false): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ status, stdout, stderr: detail ? `${stderr}${detail}` : stderr, timedOut });
    };
    let child: ChildProcess;
    try {
      child = spawn(command, [...args], {
        cwd: options.cwd,
        env: options.env,
        stdio: ["pipe", "pipe", "pipe"],
        detached: !isWindows,
        windowsHide: true,
      });
    } catch (error) {
      finish(null, error instanceof Error ? error.message : String(error));
      return;
    }
    const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    timer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) killTree(child);
      // Settle now rather than on "close": a descendant that escaped the kill
      // could hold the stdout pipe open and turn the bound back into a hang.
      child.stdout?.destroy();
      child.stderr?.destroy();
      finish(null, `${command} ${args[0] ?? ""} timed out after ${timeoutMs} ms; its process tree was killed`, true);
    }, timeoutMs);
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      if (settled) return;
      const bytes = Buffer.byteLength(chunk, "utf8");
      if (stdoutBytes + bytes > maxBuffer) {
        child.kill();
        finish(null, `stdout exceeded ${maxBuffer} bytes`);
        return;
      }
      stdout += chunk;
      stdoutBytes += bytes;
    });
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
      if (settled) return;
      const bytes = Buffer.byteLength(chunk, "utf8");
      if (stderrBytes + bytes > maxBuffer) {
        child.kill();
        finish(null, `stderr exceeded ${maxBuffer} bytes`);
        return;
      }
      stderr += chunk;
      stderrBytes += bytes;
    });
    // "close" rather than "exit": it fires once the captured stdio streams are
    // drained, so no output is lost the way an early "exit" would lose it.
    child.on("close", (code) => finish(code));
    child.on("error", (error: Error) => finish(null, error.message));
    if (child.stdin) {
      // A child that exits before reading stdin makes the write fail with
      // EPIPE, which is its answer, not this helper's failure.
      child.stdin.on("error", () => {});
      child.stdin.end(options.input ?? "");
    }
  });
}
