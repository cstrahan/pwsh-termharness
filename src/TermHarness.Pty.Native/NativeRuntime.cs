// Points the Wasmtime binding at the engine the module ships.
//
// Wasmtime.Dotnet declares [DllImport("wasmtime")], and the runtime looks that name up in the
// application's folders, never in a module's lib\. On Windows, loading the engine by full path
// first is enough, since a later lookup by name finds the module already in the process. On
// Linux and macOS it is not: dlopen by name only returns an already-loaded library when its
// SONAME matches, and the name .NET probes for ("libwasmtime.so") is not one it registered
// under. So the binding's imports are resolved here, to the handle of the engine we loaded.
using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace TermHarness.Pty
{
    public static class NativeRuntime
    {
        static IntPtr _engine = IntPtr.Zero;
        static bool _registered;

        /// Loads the wasmtime engine from the given path and makes the binding use it.
        public static void UseEngine(string path)
        {
            if (_engine != IntPtr.Zero) { return; }
            _engine = NativeLibrary.Load(path);
            if (_registered) { return; }
            // Only one resolver per assembly may ever be set; a second call throws.
            NativeLibrary.SetDllImportResolver(typeof(Wasmtime.Engine).Assembly, Resolve);
            _registered = true;
        }

        static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? searchPath)
        {
            if (name == "wasmtime" || name == "libwasmtime") { return _engine; }
            return IntPtr.Zero;
        }
    }
}
