import java.io.BufferedReader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import se.krka.kahlua.converter.KahluaConverterManager;
import se.krka.kahlua.j2se.J2SEPlatform;
import se.krka.kahlua.luaj.compiler.LuaCompiler;
import se.krka.kahlua.vm.JavaFunction;
import se.krka.kahlua.vm.KahluaTable;
import se.krka.kahlua.vm.KahluaThread;
import se.krka.kahlua.vm.LuaClosure;
import zombie.Lua.KahluaNumberConverter;
import zombie.Lua.LuaManager;
import zombie.ZomboidFileSystem;

public final class NativeStoreCheck {
    public static void main(String[] args) throws Exception {
        Path root = Path.of(args[0]).toRealPath();
        Path temporary = Files.createTempDirectory("lootbox-native-storage-");
        try {
            Path home = Files.createDirectory(temporary.resolve("home"));
            System.setProperty("user.home", home.toString());
            Path cache = temporary.resolve("cache");
            ZomboidFileSystem.instance.setCacheDir(cache.toString());
            J2SEPlatform platform = J2SEPlatform.getInstance();
            KahluaTable environment = platform.newEnvironment();
            KahluaThread thread = new KahluaThread(System.out, platform, environment);
            thread.debugOwnerThread = Thread.currentThread();
            KahluaConverterManager converters = new KahluaConverterManager();
            KahluaNumberConverter.install(converters);
            LuaManager.Exposer exposer = new LuaManager.Exposer(converters, platform, environment);
            exposer.setExposed(BufferedReader.class);
            exposer.setExposed(LuaManager.GlobalObject.LuaFileWriter.class);
            exposer.exposeLikeJava(BufferedReader.class, environment);
            exposer.exposeLikeJava(LuaManager.GlobalObject.LuaFileWriter.class, environment);
            exposer.exposeGlobalClassFunction(environment, LuaManager.GlobalObject.class,
                LuaManager.GlobalObject.class.getMethod("getFileReader", String.class, boolean.class), "getFileReader");
            exposer.exposeGlobalClassFunction(environment, LuaManager.GlobalObject.class,
                LuaManager.GlobalObject.class.getMethod("getFileWriter", String.class, boolean.class, boolean.class), "getFileWriter");
            environment.rawset("NativeUnicodeFixture", "Médicaments 医療 🧰");
            Path modules = root.resolve("Contents/mods/LootBox/42/media/lua/client");
            Map<String, Object> loaded = new HashMap<>();
            environment.rawset("require", (JavaFunction) (frame, count) -> {
                String name = (String) frame.get(0);
                if (!loaded.containsKey(name)) {
                    Path file = modules.resolve(name + ".lua").normalize();
                    if (!file.startsWith(modules)) throw new IllegalArgumentException("Module outside runtime");
                    try {
                        LuaClosure closure = LuaCompiler.loadstring(Files.readString(file), name, environment);
                        Object value = thread.call(closure, new Object[0]);
                        loaded.put(name, value == null ? Boolean.TRUE : value);
                    } catch (java.io.IOException failure) {
                        throw new IllegalArgumentException("Cannot read " + name, failure);
                    }
                }
                return frame.push(loaded.get(name));
            });
            LuaClosure suite = LuaCompiler.loadstring(Files.readString(root.resolve("tests/native-store.lua")), "native-store", environment);
            thread.call(suite, new Object[0]);
            if (!Files.isRegularFile(cache.resolve("Lua/LootBox/categories.a.txt"))
                || !Files.isRegularFile(cache.resolve("Lua/LootBox/categories.b.txt"))) {
                throw new IllegalStateException("Native slot files were not created in the isolated Lua cache");
            }
            System.out.println("NATIVE STORE PASS actual game file API, isolated cache, production Store");
        } finally {
            try (var paths = Files.walk(temporary)) {
                for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
    }
}
