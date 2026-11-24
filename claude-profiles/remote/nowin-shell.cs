// nowin-shell: the remote box's OpenSSH DefaultShell. sshd (run as the user, inside the desktop
// session) would give every command's cmd.exe a VISIBLE console window that steals focus. This
// GUI-subsystem stub (no console of its own) starts cmd.exe with CREATE_NO_WINDOW instead,
// handing it sshd's stdin/stdout/stderr pipes unchanged, and returns cmd's exit code.
// Interactive (pty) sessions already have a pseudo console attached → plain cmd.exe on it.
// Build: csc /target:winexe /out:nowin-shell.exe nowin-shell.cs   (windows-setup.ps1 does it)
using System;
using System.Runtime.InteropServices;
using System.Text;

static class NoWinShell
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();

    const uint CREATE_NO_WINDOW = 0x08000000;
    const int STARTF_USESTDHANDLES = 0x100;

    static int Main()
    {
        string cmdExe = Environment.ExpandEnvironmentVariables(@"%SystemRoot%\System32\cmd.exe");
        // Pass our raw command line on verbatim (minus argv[0]): "/c <command>" or "" (interactive).
        string rest = SkipArg0(Environment.CommandLine);
        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
        uint flags = 0;
        if (GetConsoleWindow() == IntPtr.Zero)   // no pty: sshd gave us pipes → keep them, no window
        {
            flags = CREATE_NO_WINDOW;
            si.dwFlags = STARTF_USESTDHANDLES;
            si.hStdInput = GetStdHandle(-10); si.hStdOutput = GetStdHandle(-11); si.hStdError = GetStdHandle(-12);
        }
        var line = new StringBuilder("\"" + cmdExe + "\" " + rest);
        PROCESS_INFORMATION pi;
        if (!CreateProcess(cmdExe, line, IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, null, ref si, out pi))
        {
            Console.Error.WriteLine("nowin-shell: cannot start cmd.exe (error " + Marshal.GetLastWin32Error() + ")");
            return 255;
        }
        WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
        uint code; GetExitCodeProcess(pi.hProcess, out code);
        return (int)code;
    }

    static string SkipArg0(string s)
    {
        int i = 0;
        if (s.StartsWith("\"")) i = s.IndexOf('"', 1) + 1;
        else while (i < s.Length && s[i] != ' ') i++;
        return s.Substring(i).TrimStart();
    }
}
