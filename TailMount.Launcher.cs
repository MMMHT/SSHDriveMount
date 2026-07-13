using System;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;
using System.Reflection;

[assembly: AssemblyTitle("TailMount")]
[assembly: AssemblyProduct("TailMount")]
[assembly: AssemblyDescription("Tailscale SFTP Drive Manager")]
[assembly: AssemblyCompany("MMMHT")]
[assembly: AssemblyCopyright("Copyright © 2026 MMMHT")]
[assembly: AssemblyVersion("0.2.0.0")]
[assembly: AssemblyFileVersion("0.2.0.0")]

internal static class TailMountLauncher
{
    [STAThread]
    private static void Main()
    {
        bool createdNew;
        using (Mutex singleInstance = new Mutex(true, @"Local\TailMount.SingleInstance", out createdNew))
        {
            if (!createdNew)
            {
                MessageBox.Show(
                    "TailMount 已在运行，请切换到现有窗口。",
                    "TailMount",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
                return;
            }

            try
            {
                string appDirectory = AppDomain.CurrentDomain.BaseDirectory;
                string scriptPath = Path.Combine(appDirectory, "TailMount.ps1");
                if (!File.Exists(scriptPath))
                {
                    MessageBox.Show(
                        "找不到 TailMount.ps1。请保持启动程序和脚本在同一个文件夹。",
                        "TailMount",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                    return;
                }

                Environment.SetEnvironmentVariable("TAILMOUNT_APPROOT", appDirectory);
                if (File.Exists(Path.Combine(appDirectory, "installed.marker")))
                {
                    string dataDirectory = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                        "TailMount",
                        "data");
                    Environment.SetEnvironmentVariable("TAILMOUNT_DATAROOT", dataDirectory);
                }

                using (Runspace runspace = RunspaceFactory.CreateRunspace())
                {
                    runspace.ApartmentState = ApartmentState.STA;
                    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    runspace.Open();

                    using (PowerShell powershell = PowerShell.Create())
                    {
                        powershell.Runspace = runspace;
                        powershell.AddScript(File.ReadAllText(scriptPath), true);
                        powershell.Invoke();

                        // WPF event handlers may write recoverable diagnostics to
                        // PowerShell's error stream during normal shutdown. Only
                        // show a launcher error when the entire invocation failed.
                        if (powershell.InvocationStateInfo.State == PSInvocationState.Failed)
                        {
                            string details = string.Join(
                                Environment.NewLine,
                                powershell.Streams.Error.Select(error => error.ToString()).ToArray());
                            throw new InvalidOperationException(details);
                        }
                    }
                }
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    "TailMount 启动失败：\r\n\r\n" + exception.Message,
                    "TailMount",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }
    }
}

