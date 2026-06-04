import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

public final class AddPummelchenServer {
    private static final byte TAG_END = 0;
    private static final byte TAG_BYTE = 1;
    private static final byte TAG_STRING = 8;
    private static final byte TAG_LIST = 9;
    private static final byte TAG_COMPOUND = 10;

    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            throw new IllegalArgumentException("usage: AddPummelchenServer <minecraft-dir> <server-name> <server-address>");
        }
        Path minecraftDir = Path.of(args[0]);
        String serverName = args[1];
        String serverAddress = args[2];
        Files.createDirectories(minecraftDir);

        Path serversDat = minecraftDir.resolve("servers.dat");
        byte[] next;
        if (Files.exists(serversDat)) {
            byte[] existing = Files.readAllBytes(serversDat);
            try {
                UpsertResult result = upsertServer(existing, serverName, serverAddress);
                if (!result.changed) {
                    System.out.println("Pummelchen server entry already exists.");
                    return;
                }
                backup(serversDat);
                next = result.data;
                if (result.removedDuplicates > 0) {
                    System.out.printf("Removed %d duplicate Pummelchen server entr%s.%n",
                        result.removedDuplicates,
                        result.removedDuplicates == 1 ? "y" : "ies");
                }
            } catch (RuntimeException ex) {
                backup(serversDat);
                next = singleServerFile(serverName, serverAddress);
            }
        } else {
            next = singleServerFile(serverName, serverAddress);
        }
        Files.write(serversDat, next);
        System.out.println("Pummelchen server entry is ready.");
    }

    private static void backup(Path file) throws IOException {
        String stamp = Instant.now().toString().replace(":", "").replace(".", "");
        Files.copy(file, file.resolveSibling("servers.dat.pummelchen-backup-" + stamp), StandardCopyOption.REPLACE_EXISTING);
    }

    private static UpsertResult upsertServer(byte[] data, String name, String ip) throws IOException {
        Cursor cursor = new Cursor(data);
        if (cursor.u8() != TAG_COMPOUND) {
            throw new IllegalArgumentException("root is not a compound");
        }
        cursor.utf();
        while (cursor.pos < data.length) {
            int type = cursor.u8();
            if (type == TAG_END) {
                break;
            }
            String tagName = cursor.utf();
            int payloadStart = cursor.pos;
            if (type == TAG_LIST && "servers".equals(tagName)) {
                int childType = cursor.u8();
                int countPos = cursor.pos;
                int count = cursor.i32();
                if (childType != TAG_COMPOUND || count < 0) {
                    throw new IllegalArgumentException("servers list is not a compound list");
                }
                List<byte[]> entries = new ArrayList<>(count);
                for (int i = 0; i < count; i++) {
                    int entryStart = cursor.pos;
                    skipCompoundPayload(cursor);
                    int entryEnd = cursor.pos;
                    entries.add(Arrays.copyOfRange(data, entryStart, entryEnd));
                }
                int compoundsEnd = cursor.pos;
                List<byte[]> nextEntries = dedupeAndUpsert(entries, name, ip);
                boolean changed = nextEntries.size() != entries.size();
                if (!changed) {
                    for (int i = 0; i < entries.size(); i++) {
                        if (!Arrays.equals(entries.get(i), nextEntries.get(i))) {
                            changed = true;
                            break;
                        }
                    }
                }
                if (!changed) {
                    return new UpsertResult(data, false, 0);
                }
                ByteArrayOutputStream out = new ByteArrayOutputStream(data.length + 256);
                out.write(data, 0, countPos);
                writeInt(out, nextEntries.size());
                for (byte[] entry : nextEntries) {
                    out.write(entry);
                }
                out.write(data, compoundsEnd, data.length - compoundsEnd);
                int removed = Math.max(0, entries.size() - nextEntries.size());
                return new UpsertResult(out.toByteArray(), true, removed);
            }
            cursor.pos = payloadStart;
            skipPayload(cursor, type);
        }
        return new UpsertResult(singleServerFile(name, ip), true, 0);
    }

    private static List<byte[]> dedupeAndUpsert(List<byte[]> entries, String name, String ip) throws IOException {
        String targetAddress = normalizeAddress(ip);
        List<byte[]> next = new ArrayList<>(entries.size() + 1);
        boolean inserted = false;
        for (byte[] entry : entries) {
            ServerEntry server = readServerEntry(entry);
            boolean sameAddress = targetAddress.equals(normalizeAddress(server.ip));
            boolean sameName = server.name != null && server.name.equalsIgnoreCase(name);
            if (sameAddress || sameName) {
                if (!inserted) {
                    next.add(serverCompound(name, ip));
                    inserted = true;
                }
                continue;
            }
            next.add(entry);
        }
        if (!inserted) {
            next.add(serverCompound(name, ip));
        }
        return next;
    }

    private static ServerEntry readServerEntry(byte[] compoundPayload) {
        Cursor cursor = new Cursor(compoundPayload);
        String name = null;
        String ip = null;
        while (cursor.pos < compoundPayload.length) {
            int type = cursor.u8();
            if (type == TAG_END) {
                return new ServerEntry(name, ip);
            }
            String tagName = cursor.utf();
            if (type == TAG_STRING && "name".equals(tagName)) {
                name = cursor.utf();
            } else if (type == TAG_STRING && "ip".equals(tagName)) {
                ip = cursor.utf();
            } else {
                skipPayload(cursor, type);
            }
        }
        throw new IllegalArgumentException("unterminated server compound");
    }

    private static String normalizeAddress(String address) {
        if (address == null) {
            return "";
        }
        String value = address.trim().toLowerCase(Locale.ROOT);
        if (value.isEmpty()) {
            return value;
        }
        if (value.startsWith("[") && value.contains("]")) {
            int close = value.indexOf(']');
            if (close == value.length() - 1) {
                return value + ":25565";
            }
            return value;
        }
        int firstColon = value.indexOf(':');
        int lastColon = value.lastIndexOf(':');
        if (firstColon < 0) {
            return value + ":25565";
        }
        if (firstColon == lastColon && lastColon == value.length() - 1) {
            return value.substring(0, lastColon) + ":25565";
        }
        return value;
    }

    private static byte[] singleServerFile(String name, String ip) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(256);
        DataOutputStream data = new DataOutputStream(out);
        data.writeByte(TAG_COMPOUND);
        data.writeUTF("");
        data.writeByte(TAG_LIST);
        data.writeUTF("servers");
        data.writeByte(TAG_COMPOUND);
        data.writeInt(1);
        data.write(serverCompound(name, ip));
        data.writeByte(TAG_END);
        data.flush();
        return out.toByteArray();
    }

    private static byte[] serverCompound(String name, String ip) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(192);
        DataOutputStream data = new DataOutputStream(out);
        data.writeByte(TAG_STRING);
        data.writeUTF("name");
        data.writeUTF(name);
        data.writeByte(TAG_STRING);
        data.writeUTF("ip");
        data.writeUTF(ip);
        data.writeByte(TAG_BYTE);
        data.writeUTF("acceptTextures");
        data.writeByte(1);
        data.writeByte(TAG_BYTE);
        data.writeUTF("hideAddress");
        data.writeByte(0);
        data.writeByte(TAG_END);
        data.flush();
        return out.toByteArray();
    }

    private static void skipCompoundPayload(Cursor cursor) {
        while (cursor.pos < cursor.data.length) {
            int type = cursor.u8();
            if (type == TAG_END) {
                return;
            }
            cursor.utf();
            skipPayload(cursor, type);
        }
        throw new IllegalArgumentException("unterminated compound");
    }

    private static void skipPayload(Cursor cursor, int type) {
        switch (type) {
            case 1 -> cursor.skip(1);
            case 2 -> cursor.skip(2);
            case 3, 5 -> cursor.skip(4);
            case 4, 6 -> cursor.skip(8);
            case 7 -> cursor.skip(cursor.i32());
            case 8 -> cursor.utf();
            case 9 -> {
                int childType = cursor.u8();
                int count = cursor.i32();
                if (count < 0) {
                    throw new IllegalArgumentException("negative list size");
                }
                for (int i = 0; i < count; i++) {
                    skipPayload(cursor, childType);
                }
            }
            case 10 -> skipCompoundPayload(cursor);
            case 11 -> cursor.skip(Math.multiplyExact(cursor.i32(), 4));
            case 12 -> cursor.skip(Math.multiplyExact(cursor.i32(), 8));
            default -> throw new IllegalArgumentException("unknown NBT tag " + type);
        }
    }

    private static void writeInt(ByteArrayOutputStream out, int value) {
        out.write((value >>> 24) & 0xff);
        out.write((value >>> 16) & 0xff);
        out.write((value >>> 8) & 0xff);
        out.write(value & 0xff);
    }

    private static final class ServerEntry {
        final String name;
        final String ip;

        ServerEntry(String name, String ip) {
            this.name = name;
            this.ip = ip;
        }
    }

    private static final class UpsertResult {
        final byte[] data;
        final boolean changed;
        final int removedDuplicates;

        UpsertResult(byte[] data, boolean changed, int removedDuplicates) {
            this.data = data;
            this.changed = changed;
            this.removedDuplicates = removedDuplicates;
        }
    }

    private static final class Cursor {
        final byte[] data;
        int pos;

        Cursor(byte[] data) {
            this.data = data;
        }

        int u8() {
            require(1);
            return data[pos++] & 0xff;
        }

        int i32() {
            require(4);
            int value = ((data[pos] & 0xff) << 24)
                | ((data[pos + 1] & 0xff) << 16)
                | ((data[pos + 2] & 0xff) << 8)
                | (data[pos + 3] & 0xff);
            pos += 4;
            return value;
        }

        String utf() {
            require(2);
            int len = ((data[pos] & 0xff) << 8) | (data[pos + 1] & 0xff);
            pos += 2;
            require(len);
            String value = new String(Arrays.copyOfRange(data, pos, pos + len), java.nio.charset.StandardCharsets.UTF_8);
            pos += len;
            return value;
        }

        void skip(int count) {
            if (count < 0) {
                throw new IllegalArgumentException("negative skip");
            }
            require(count);
            pos += count;
        }

        void require(int count) {
            if (pos + count > data.length) {
                throw new IllegalArgumentException("truncated NBT");
            }
        }
    }
}
