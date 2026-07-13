using System;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;

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

