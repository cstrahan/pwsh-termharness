// A pseudo terminal on Linux and macOS: the Unix counterpart of PtyNative.cs.
//
// The master side is opened with posix_openpt, and the program is started with posix_spawn
// rather than fork: forking a .NET process is unsafe (the runtime is multithreaded), and
// posix_spawn can do everything the classic forkpty recipe needs. The child is made a session
// leader (POSIX_SPAWN_SETSID) and its standard handles are opened *by path* in the child
// (posix_spawn_file_actions_addopen on /dev/pts/N): a session leader that opens a terminal it
// doesn't yet have acquires it as its controlling terminal, which is what gives the program job
// control, SIGHUP on close and SIGWINCH on resize. Dup'ing an already-open descriptor would not.
//
// This process also keeps its own descriptor on the slave. Without one, reading the master
// before the child has opened the slave, or after it has closed it, fails with EIO on Linux
// instead of blocking; with one, output that arrived just before the program exited is still
// readable, and exit is detected with waitpid instead.
//
// Resizing is one ioctl on the master, except on macOS on Apple silicon: ioctl is variadic, and
// Apple's arm64 ABI passes variadic arguments on the stack, so a P/Invoke declared with fixed
// parameters passes the pointer in a register the callee never reads. There, stty does the
// ioctl for us, started against the slave the same way the program is.
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace TermHarness.Pty
{
    /// A running program and the pseudo terminal it is attached to.
    public class UnixPtyProcess
    {
        /// The master descriptor, which Output reads. Input writes a dup of it.
        public int Master = -1;
        /// Our own open of the slave; see the file comment.
        public int SlaveHold = -1;
        public string SlavePath;
        public int ProcessId;
        public bool Exited;
        public int ExitStatus;
        /// What the program reads as its input.
        public FileStream Input;
        /// What the program writes: a VT stream, for a terminal emulator to interpret.
        public FileStream Output;
    }

    public static class UnixNative
    {
        const string Libc = "libc";

        static readonly bool IsMacOS = RuntimeInformation.IsOSPlatform(OSPlatform.OSX);

        // The numbers that differ between the two platforms.
        static readonly int O_NOCTTY = IsMacOS ? 0x20000 : 0x100;
        static readonly short POSIX_SPAWN_SETSID = IsMacOS ? (short)0x0400 : (short)0x80;
        const short POSIX_SPAWN_SETSIGDEF = 0x04;
        const short POSIX_SPAWN_SETSIGMASK = 0x08;
        static readonly UIntPtr TIOCSWINSZ = IsMacOS ? (UIntPtr)0x80087467 : (UIntPtr)0x5414;

        const int O_RDWR = 2;
        const int F_SETFD = 2;
        const int FD_CLOEXEC = 1;
        const int WNOHANG = 1;
        const int SIGHUP = 1;
        const int SIGKILL = 9;
        const int ECHILD = 10;
        // Generous: glibc's posix_spawnattr_t is 336 bytes and sigset_t 128; macOS's are smaller.
        const int OPAQUE_SIZE = 512;

        static UnixNative()
        {
            // "libc" is not a file on either platform: glibc's libc.so is a linker script, and
            // macOS wants libSystem. Resolve the name ourselves.
            NativeLibrary.SetDllImportResolver(typeof(UnixNative).Assembly, ResolveLibrary);
        }

        static IntPtr ResolveLibrary(string name, Assembly assembly, DllImportSearchPath? searchPath)
        {
            if (name != Libc) { return IntPtr.Zero; }
            string[] candidates = IsMacOS
                ? new[] { "libSystem.dylib", "/usr/lib/libSystem.B.dylib" }
                : new[] { "libc.so.6", "libc.so", "libc.musl-x86_64.so.1", "libc.musl-aarch64.so.1" };
            foreach (var candidate in candidates)
            {
                IntPtr handle;
                if (NativeLibrary.TryLoad(candidate, out handle)) { return handle; }
            }
            return IntPtr.Zero;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WinSize { public ushort Rows, Columns, XPixels, YPixels; }

        [DllImport(Libc, SetLastError = true)] static extern int posix_openpt(int flags);
        [DllImport(Libc, SetLastError = true)] static extern int grantpt(int fd);
        [DllImport(Libc, SetLastError = true)] static extern int unlockpt(int fd);
        [DllImport(Libc, SetLastError = true)] static extern IntPtr ptsname(int fd);
        [DllImport(Libc, SetLastError = true)] static extern int open([MarshalAs(UnmanagedType.LPStr)] string path, int flags);
        [DllImport(Libc, SetLastError = true)] static extern int close(int fd);
        [DllImport(Libc, SetLastError = true)] static extern int dup(int fd);
        [DllImport(Libc, SetLastError = true)] static extern int fcntl(int fd, int command, int argument);
        [DllImport(Libc, SetLastError = true)] static extern int ioctl(int fd, UIntPtr request, ref WinSize size);
        [DllImport(Libc, SetLastError = true)] static extern int kill(int pid, int signal);
        [DllImport(Libc, SetLastError = true)] static extern int waitpid(int pid, out int status, int options);
        [DllImport(Libc)] static extern int sigemptyset(IntPtr set);
        [DllImport(Libc)] static extern int sigfillset(IntPtr set);
        [DllImport(Libc)] static extern int posix_spawn_file_actions_init(IntPtr actions);
        [DllImport(Libc)] static extern int posix_spawn_file_actions_destroy(IntPtr actions);
        [DllImport(Libc)] static extern int posix_spawn_file_actions_addopen(IntPtr actions, int fd, [MarshalAs(UnmanagedType.LPStr)] string path, int flags, uint mode);
        [DllImport(Libc)] static extern int posix_spawn_file_actions_adddup2(IntPtr actions, int fd, int newFd);
        [DllImport(Libc)] static extern int posix_spawnattr_init(IntPtr attributes);
        [DllImport(Libc)] static extern int posix_spawnattr_destroy(IntPtr attributes);
        [DllImport(Libc)] static extern int posix_spawnattr_setflags(IntPtr attributes, short flags);
        [DllImport(Libc)] static extern int posix_spawnattr_setsigdefault(IntPtr attributes, IntPtr set);
        [DllImport(Libc)] static extern int posix_spawnattr_setsigmask(IntPtr attributes, IntPtr set);
        [DllImport(Libc, SetLastError = true)]
        static extern int posix_spawnp(out int pid, [MarshalAs(UnmanagedType.LPStr)] string file, IntPtr actions, IntPtr attributes,
            [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPStr)] string[] argv,
            [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPStr)] string[] envp);

        static Win32Exception LastError(string what)
        {
            var code = Marshal.GetLastWin32Error();
            return new Win32Exception(code, what + " failed: errno " + code);
        }

        static void CloseOnExec(int fd)
        {
            // posix_spawn hands every inheritable descriptor to the child; the pty's own ends must
            // not go along, or the child could never see end-of-file on them.
            if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) { throw LastError("fcntl(FD_CLOEXEC)"); }
        }

        public static UnixPtyProcess Start(string commandLine, string workingDirectory, short columns, short rows)
        {
            int master = posix_openpt(O_RDWR | O_NOCTTY);
            if (master < 0) { throw LastError("posix_openpt"); }
            if (grantpt(master) != 0) { throw LastError("grantpt"); }
            if (unlockpt(master) != 0) { throw LastError("unlockpt"); }
            var slavePath = Marshal.PtrToStringAnsi(ptsname(master));
            if (string.IsNullOrEmpty(slavePath)) { throw LastError("ptsname"); }
            CloseOnExec(master);

            int hold = open(slavePath, O_RDWR | O_NOCTTY);
            if (hold < 0) { throw LastError("open(" + slavePath + ")"); }
            CloseOnExec(hold);

            var pty = new UnixPtyProcess { Master = master, SlaveHold = hold, SlavePath = slavePath };
            Resize(pty, columns, rows);

            // /bin/sh runs the command line, the way a terminal would: 'cd' into the working
            // directory first, and exec so the program is the shell's replacement, not its child.
            var argv = new[] {
                "/bin/sh", "-c", "cd -- \"$1\" && exec /bin/sh -c \"$2\"", "termharness",
                string.IsNullOrEmpty(workingDirectory) ? "." : workingDirectory, commandLine, null
            };
            pty.ProcessId = Spawn("/bin/sh", argv, slavePath, true);

            int writer = dup(master);
            if (writer < 0) { throw LastError("dup"); }
            CloseOnExec(writer);
            // Unbuffered (bufferSize 1): each write must reach the program at once, and a read
            // must return whatever has arrived rather than waiting to fill a buffer.
            pty.Output = new FileStream(new SafeFileHandle((IntPtr)master, true), FileAccess.Read, 1);
            pty.Input = new FileStream(new SafeFileHandle((IntPtr)writer, true), FileAccess.Write, 1);
            return pty;
        }

        /// Starts a program with the slave as its standard handles. As a session leader, so it
        /// acquires the terminal, or not, for helpers like stty that must leave it alone.
        static int Spawn(string file, string[] argv, string slavePath, bool sessionLeader)
        {
            IntPtr actions = Marshal.AllocHGlobal(OPAQUE_SIZE);
            IntPtr attributes = Marshal.AllocHGlobal(OPAQUE_SIZE);
            IntPtr allSignals = Marshal.AllocHGlobal(OPAQUE_SIZE);
            IntPtr noSignals = Marshal.AllocHGlobal(OPAQUE_SIZE);
            try
            {
                Check(posix_spawn_file_actions_init(actions), "posix_spawn_file_actions_init");
                // Opened in the child, by path, without O_NOCTTY when the child is to own it.
                int flags = sessionLeader ? O_RDWR : O_RDWR | O_NOCTTY;
                Check(posix_spawn_file_actions_addopen(actions, 0, slavePath, flags, 0), "posix_spawn_file_actions_addopen");
                Check(posix_spawn_file_actions_adddup2(actions, 0, 1), "posix_spawn_file_actions_adddup2(1)");
                Check(posix_spawn_file_actions_adddup2(actions, 0, 2), "posix_spawn_file_actions_adddup2(2)");

                Check(posix_spawnattr_init(attributes), "posix_spawnattr_init");
                // The .NET runtime ignores SIGPIPE and blocks some signals; a program under test
                // should start with the defaults a terminal would give it.
                sigfillset(allSignals);
                sigemptyset(noSignals);
                Check(posix_spawnattr_setsigdefault(attributes, allSignals), "posix_spawnattr_setsigdefault");
                Check(posix_spawnattr_setsigmask(attributes, noSignals), "posix_spawnattr_setsigmask");
                short spawnFlags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
                if (sessionLeader) { spawnFlags |= POSIX_SPAWN_SETSID; }
                Check(posix_spawnattr_setflags(attributes, spawnFlags), "posix_spawnattr_setflags");

                int pid;
                int result = posix_spawnp(out pid, file, actions, attributes, argv, Environment(sessionLeader));
                if (result != 0)
                {
                    throw new Win32Exception(result, "posix_spawnp failed for " + file + ": errno " + result);
                }
                return pid;
            }
            finally
            {
                posix_spawnattr_destroy(attributes);
                posix_spawn_file_actions_destroy(actions);
                Marshal.FreeHGlobal(noSignals);
                Marshal.FreeHGlobal(allSignals);
                Marshal.FreeHGlobal(attributes);
                Marshal.FreeHGlobal(actions);
            }
        }

        static void Check(int result, string what)
        {
            if (result != 0) { throw new Win32Exception(result, what + " failed: " + result); }
        }

        /// This process's environment, with TERM set to what libghostty-vt emulates.
        static string[] Environment(bool forProgram)
        {
            var entries = new List<string>();
            foreach (DictionaryEntry entry in System.Environment.GetEnvironmentVariables())
            {
                var key = (string)entry.Key;
                if (forProgram && key == "TERM") { continue; }
                entries.Add(key + "=" + entry.Value);
            }
            if (forProgram) { entries.Add("TERM=xterm-256color"); }
            entries.Add(null);
            return entries.ToArray();
        }

        public static void Resize(UnixPtyProcess pty, short columns, short rows)
        {
            if (IsMacOS)
            {
                // See the file comment: no variadic ioctl through P/Invoke on Apple silicon.
                var argv = new[] { "stty", "rows", rows.ToString(), "cols", columns.ToString(), null };
                int pid = Spawn("stty", argv, pty.SlavePath, false);
                int status;
                while (waitpid(pid, out status, 0) < 0 && Marshal.GetLastWin32Error() != ECHILD) { }
                return;
            }
            var size = new WinSize { Rows = (ushort)rows, Columns = (ushort)columns };
            if (ioctl(pty.Master, TIOCSWINSZ, ref size) != 0) { throw LastError("ioctl(TIOCSWINSZ)"); }
        }

        public static bool HasExited(UnixPtyProcess pty)
        {
            if (pty.Exited || pty.ProcessId <= 0) { return true; }
            int status;
            int result = waitpid(pty.ProcessId, out status, WNOHANG);
            if (result == 0) { return false; }
            // Reaped, or already reaped by someone else (ECHILD): gone either way.
            pty.Exited = true;
            pty.ExitStatus = result > 0 ? status : -1;
            return true;
        }

        public static void Stop(UnixPtyProcess pty)
        {
            if (pty == null) { return; }
            if (pty.ProcessId > 0 && !HasExited(pty))
            {
                // The session leader's whole process group first, politely: SIGHUP is what a
                // closing terminal sends. Then everything still in the session, and by force.
                kill(-pty.ProcessId, SIGHUP);
                WaitForExit(pty, 500);
                if (!HasExited(pty))
                {
                    kill(-pty.ProcessId, SIGKILL);
                    KillSession(pty.ProcessId);
                    WaitForExit(pty, 2000);
                }
                else
                {
                    KillSession(pty.ProcessId);
                }
            }
            try { if (pty.Input != null) { pty.Input.Dispose(); } } catch { }
            try { if (pty.Output != null) { pty.Output.Dispose(); } } catch { }
            if (pty.SlaveHold >= 0) { close(pty.SlaveHold); pty.SlaveHold = -1; }
            pty.Master = -1;
        }

        static void WaitForExit(UnixPtyProcess pty, int milliseconds)
        {
            var deadline = DateTime.UtcNow.AddMilliseconds(milliseconds);
            while (!HasExited(pty) && DateTime.UtcNow < deadline) { Thread.Sleep(20); }
        }

        /// Kills every process whose session is the one the program leads. A shell with job
        /// control puts each job in its own process group, so a group kill alone can miss them.
        /// Linux only: /proc says which session a process belongs to; macOS has no cheap answer,
        /// and there the group kill has to do.
        static void KillSession(int sessionId)
        {
            if (IsMacOS || !Directory.Exists("/proc")) { return; }
            foreach (var directory in Directory.GetDirectories("/proc"))
            {
                int pid;
                if (!int.TryParse(Path.GetFileName(directory), out pid) || pid == sessionId) { continue; }
                string stat;
                try { stat = File.ReadAllText(Path.Combine(directory, "stat")); } catch { continue; }
                // "pid (comm) state ppid pgrp session ..."; comm can contain spaces, so split
                // after its closing parenthesis.
                int end = stat.LastIndexOf(')');
                if (end < 0) { continue; }
                var fields = stat.Substring(end + 1).Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                int session;
                if (fields.Length > 3 && int.TryParse(fields[3], out session) && session == sessionId)
                {
                    kill(pid, SIGKILL);
                }
            }
        }
    }
}
