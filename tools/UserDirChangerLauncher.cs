using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

[assembly: AssemblyTitle("UserDirChanger")]
[assembly: AssemblyDescription("Windows 用户文件夹迁移工具")]
[assembly: AssemblyCompany("UserDirChanger")]
[assembly: AssemblyProduct("UserDirChanger")]
[assembly: AssemblyVersion("1.0.2")]
[assembly: AssemblyFileVersion("1.0.2")]
[assembly: AssemblyInformationalVersion("1.0.2")]

internal static class Program
{
    private const string StartResource = "UserDirChanger.Start.ps1";
    private const string EngineResource = "UserDirChanger.Move.ps1";
    private const string StartFileName = "Start-UserFolderMigration.ps1";
    private const string EngineFileName = "Move-UserFolders.ps1";

    private static int Main(string[] args)
    {
        string runtimeDirectory = null;
        try
        {
            TryConfigureConsole();
            Console.Title = "UserDirChanger v1.0.2";

            runtimeDirectory = Path.Combine(
                Path.GetTempPath(),
                "UserDirChanger",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(runtimeDirectory);

            Assembly assembly = Assembly.GetExecutingAssembly();
            ExtractResource(assembly, StartResource, Path.Combine(runtimeDirectory, StartFileName));
            ExtractResource(assembly, EngineResource, Path.Combine(runtimeDirectory, EngineFileName));

            string powerShellPath = FindPowerShell();
            ProcessStartInfo startInfo = new ProcessStartInfo
            {
                FileName = powerShellPath,
                Arguments = BuildPowerShellArguments(runtimeDirectory, args),
                WorkingDirectory = runtimeDirectory,
                UseShellExecute = false,
                CreateNoWindow = false
            };

            using (Process process = Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException("无法创建 PowerShell 进程。");
                }
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception exception)
        {
            Console.WriteLine();
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine("启动失败：" + exception.Message);
            Console.ResetColor();
            Console.WriteLine("请确认你在 Windows 11 上运行，并且系统 PowerShell 未被删除。");
            PauseOnError();
            return 1;
        }
        finally
        {
            Cleanup(runtimeDirectory);
        }
    }

    private static string FindPowerShell()
    {
        string systemRoot = Environment.GetEnvironmentVariable("SystemRoot");
        if (!String.IsNullOrEmpty(systemRoot))
        {
            string candidate = Path.Combine(
                systemRoot,
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        return "powershell.exe";
    }

    private static void ExtractResource(Assembly assembly, string resourceName, string destinationPath)
    {
        using (Stream input = assembly.GetManifestResourceStream(resourceName))
        {
            if (input == null)
            {
                throw new InvalidOperationException("EXE 内嵌脚本缺失：" + resourceName);
            }
            using (FileStream output = new FileStream(
                destinationPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None))
            {
                input.CopyTo(output);
            }
        }
    }

    private static string BuildPowerShellArguments(string runtimeDirectory, string[] args)
    {
        StringBuilder builder = new StringBuilder();
        AppendArgument(builder, "-NoProfile");
        AppendArgument(builder, "-ExecutionPolicy");
        AppendArgument(builder, "Bypass");
        AppendArgument(builder, "-File");
        AppendArgument(builder, Path.Combine(runtimeDirectory, StartFileName));

        foreach (string argument in args)
        {
            string forwarded = String.Equals(argument, "--preview", StringComparison.OrdinalIgnoreCase)
                ? "-Preview"
                : argument;
            AppendArgument(builder, forwarded);
        }
        return builder.ToString();
    }

    private static void AppendArgument(StringBuilder builder, string value)
    {
        if (builder.Length > 0)
        {
            builder.Append(' ');
        }
        builder.Append(QuoteArgument(value));
    }

    private static string QuoteArgument(string value)
    {
        if (String.IsNullOrEmpty(value))
        {
            return "\"\"";
        }

        bool needsQuotes = false;
        foreach (char character in value)
        {
            if (Char.IsWhiteSpace(character) || character == '"')
            {
                needsQuotes = true;
                break;
            }
        }
        if (!needsQuotes)
        {
            return value;
        }

        StringBuilder quoted = new StringBuilder(value.Length + 2);
        quoted.Append('"');
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                quoted.Append('\\', backslashes * 2 + 1);
                quoted.Append('"');
                backslashes = 0;
                continue;
            }
            quoted.Append('\\', backslashes);
            backslashes = 0;
            quoted.Append(character);
        }
        quoted.Append('\\', backslashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    private static void TryConfigureConsole()
    {
        try
        {
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.InputEncoding = new UTF8Encoding(false);
        }
        catch
        {
            // PowerShell will still use the console's existing encoding.
        }
    }

    private static void PauseOnError()
    {
        try
        {
            if (!Console.IsInputRedirected)
            {
                Console.Write("按 Enter 键关闭窗口");
                Console.ReadLine();
            }
        }
        catch
        {
            // Ignore console errors while reporting the original failure.
        }
    }

    private static void Cleanup(string runtimeDirectory)
    {
        if (String.IsNullOrEmpty(runtimeDirectory))
        {
            return;
        }
        try
        {
            if (Directory.Exists(runtimeDirectory))
            {
                Directory.Delete(runtimeDirectory, true);
            }
        }
        catch
        {
            // A locked temporary file must not hide the script's exit code.
        }
    }
}
