using WorkCtlNext.Cli;
using WorkCtlNext.Core;
using WorkCtlNext.Terminal;

namespace WorkCtlNext;

public static class Program
{
    private static bool IsTuiLaunch(string[] args)
    {
        if (args.Length == 0)
            return true;

        if (string.Equals(args[0], "tui", StringComparison.OrdinalIgnoreCase))
            return true;

        foreach (string a in args)
        {
            if (a is not ("--no-anim" or "--no-color" or "--ascii" or "--reduced-motion"))
                return false;
        }
        return true;
    }

    public static async Task<int> Main(string[] args)
    {
        WorkctlPathsConfig config = WorkctlPathsConfig.FromEnvironment();
        var runner = new ProcessRunner();

        if (!IsTuiLaunch(args) && AgentCli.IsCliCommand(args))
        {
            var cliDispatcher = new CapabilityDispatcher(config, runner, policyMode: DispatcherPolicyMode.ReadOnly);
            var cli = new AgentCli(cliDispatcher, Console.Out, Console.Error);
            return await cli.ExecuteAsync(args, CancellationToken.None).ConfigureAwait(false);
        }

        var dispatcher = new CapabilityDispatcher(config, runner, policyMode: DispatcherPolicyMode.InteractivePhase2);

        var backend = new WindowsTerminalBackend();
        if (!backend.IsInteractiveTty)
        {
            Console.Error.WriteLine("WorkCtl Next TUI requires an interactive terminal (stdin/stdout cannot be redirected). Use '--help' or '--json' CLI commands for agent/script invocation.");
            return 2;
        }

        try
        {
            TuiVisualOptions visualOpts = TuiVisualOptions.FromEnvironmentAndArgs(args);
            var app = new TuiApp(dispatcher, backend, visualOpts);
            return await app.RunAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"TUI exited unexpectedly after terminal cleanup: {ex.Message}");
            return 1;
        }
    }
}
