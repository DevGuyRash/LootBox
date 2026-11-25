import java.nio.file.Files;
import java.nio.file.Path;
import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.LuaClosure;

/** Development-only interpreter check. No game client or server is started. */
public final class KahluaCheck {
    public static void main(String[] args) throws Exception {
        Path root = Path.of(args[0]).toRealPath();
        Path modules = root.resolve("Contents/mods/LootBox/42/media/lua/client");
        for (int index = 1; index < args.length; index++) {
            Path suite = root.resolve(args[index]).normalize();
            if (!suite.startsWith(root.resolve("tests"))) throw new IllegalArgumentException("Suite outside tests");
            J2SEPlatform platform = J2SEPlatform.getInstance();
            KahluaTable environment = platform.newEnvironment();
            KahluaThread thread = new KahluaThread(System.out, platform, environment);
            thread.debugOwnerThread = Thread.currentThread();
            KahluaTable packageTable = platform.newTable();
            KahluaTable loaded = platform.newTable();
            KahluaTable preload = platform.newTable();
            packageTable.rawset("path", "");
            packageTable.rawset("loaded", loaded);
            packageTable.rawset("preload", preload);
            environment.rawset("package", packageTable);
            environment.rawset("require", (JavaFunction) (frame, count) -> {
                String name = (String) frame.get(0);
                if (loaded.rawget(name) == null || Boolean.FALSE.equals(loaded.rawget(name))) {
                    if (preload.rawget(name) != null) {
                        Object value = thread.call(preload.rawget(name), new Object[0]);
                        loaded.rawset(name, value == null ? Boolean.TRUE : value);
                        return frame.push(loaded.rawget(name));
                    }
                    Path base = name.startsWith("support/") ? root.resolve("tests") : modules;
                    Path file = base.resolve(name + ".lua").normalize();
                    if (!file.startsWith(base)) throw new IllegalArgumentException("Module outside runtime");
                    try {
                        LuaClosure closure = LuaCompiler.loadstring(Files.readString(file), name, environment);
                        Object value = thread.call(closure, new Object[0]);
                        loaded.rawset(name, value == null ? Boolean.TRUE : value);
                    } catch (java.io.IOException failure) {
                        throw new IllegalArgumentException("Cannot read " + name, failure);
                    }
                }
                return frame.push(loaded.rawget(name));
            });
            System.out.println("KAHLUA " + args[index]);
            LuaClosure closure = LuaCompiler.loadstring(Files.readString(suite), args[index], environment);
            thread.call(closure, new Object[0]);
            System.out.println("KAHLUA PASS " + args[index]);
        }
    }
}
