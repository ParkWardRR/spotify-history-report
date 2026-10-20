package spotify_report

// Input adapters. A run can be pointed at a folder, a ZIP exactly as Spotify
// sends it, or loose .json files. Nothing is extracted to disk: ZIP entries are
// inflated in memory, only the ones that could be streaming history, and under
// hard size limits.

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/json"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Limits. A real Extended Streaming History is a few dozen MB uncompressed.
MAX_ZIP_BYTES        :: 2 << 30  // the archive itself (ZIP64 is not supported)
MAX_ENTRY_BYTES      :: 512 << 20 // one JSON file, expanded
MAX_EXPANDED_BYTES   :: 2 << 30  // everything we would inflate from one archive
MAX_EXPANSION_RATIO  :: 200      // a deflate stream beyond this is a bomb, not music
MAX_ZIP_ENTRIES      :: 20000
MAX_SCAN_DEPTH       :: 4
MAX_INPUT_FILES      :: 2000

Zip_Entry :: struct {
	name:         string,
	method:       u16,
	comp_size:    u32,
	size:         u32,
	local_offset: u32,
}

Zip_Archive :: struct {
	path:    string,
	data:    []u8,
	entries: [dynamic]Zip_Entry,
}

// One candidate file. It is read lazily with `read_input`.
Input_Entry :: struct {
	name:    string, // what to show the user (relative path, or archive!entry)
	path:    string, // file on disk; empty for a ZIP entry
	archive: ^Zip_Archive,
	entry:   int, // index into archive.entries
}

Scan_Result :: struct {
	entries:  [dynamic]Input_Entry,
	sidecar_dir: string, // where .shr/ lives: the folder itself, or next to a ZIP / file
	err:      string,
	hint:     string,
}

is_zip_path :: proc(path: string) -> bool {
	return strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".zip")
}

// Collects candidate .json files from every input path. A path may be a
// directory (searched a few levels deep), a .zip, or a single .json file.
scan_inputs :: proc(paths: []string) -> (r: Scan_Result) {
	if len(paths) == 0 {
		r.err = "No input given."
		r.hint = "Pass your Spotify export ZIP, the extracted folder, or the Streaming_History_Audio_*.json files."
		return
	}

	for p, i in paths {
		if !os.exists(p) {
			r.err = strings.clone(strings.concatenate({p, " does not exist."}, context.temp_allocator))
			r.hint = "Check the path. Run with --guide for how to get your Spotify export."
			return
		}
		if i == 0 do r.sidecar_dir = sidecar_dir_for(p)

		switch {
		case os.is_dir(p):
			scan_dir(&r, p, p, 0)
		case is_zip_path(p):
			scan_zip(&r, p)
		case:
			append(&r.entries, Input_Entry{name = filepath.base(p), path = p, entry = -1})
		}
		if len(r.err) > 0 do return
	}

	if len(r.entries) > MAX_INPUT_FILES {
		r.err = "Too many files."
		r.hint = "Point at the folder holding Streaming_History_Audio_*.json, not a whole drive."
		return
	}
	slice.sort_by(r.entries[:], proc(a, b: Input_Entry) -> bool { return a.name < b.name })
	return
}

// A folder keeps its sidecar inside it; a ZIP or file keeps it beside itself.
sidecar_dir_for :: proc(path: string) -> string {
	if os.is_dir(path) do return path
	dir := filepath.dir(path)
	return dir if len(dir) > 0 else "."
}

scan_dir :: proc(r: ^Scan_Result, root, dir: string, depth: int) {
	dh, err := os.open(dir)
	if err != nil do return
	defer os.close(dh)
	infos, read_err := os.read_dir(dh, -1, context.allocator)
	if read_err != nil do return

	for e in infos {
		if strings.has_prefix(e.name, ".") do continue // .shr, .git, ._AppleDouble
		full, _ := filepath.join({dir, e.name}, context.allocator)
		if e.type == .Directory {
			if depth < MAX_SCAN_DEPTH && e.name != "__MACOSX" do scan_dir(r, root, full, depth + 1)
			continue
		}
		if e.type == .Symlink do continue // never follow links out of the folder
		if strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".json") {
			rel, rel_err := filepath.rel(root, full, context.allocator)
			append(&r.entries, Input_Entry{name = full if rel_err != nil else rel, path = full, entry = -1})
		} else if is_zip_path(e.name) && depth == 0 {
			scan_zip(r, full)
			r.err = "" // a stray ZIP beside the data is not fatal
			r.hint = ""
		}
	}
}

// ── ZIP ──────────────────────────────────────────────────────────────────────

le16 :: proc(b: []u8, o: int) -> u16 { return u16(b[o]) | u16(b[o+1]) << 8 }
le32 :: proc(b: []u8, o: int) -> u32 { return u32(le16(b, o)) | u32(le16(b, o+2)) << 16 }

scan_zip :: proc(r: ^Scan_Result, path: string) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		r.err = strings.concatenate({"Could not read ", path}, context.allocator)
		r.hint = "Check that the file exists and you can open it."
		return
	}
	if len(data) > MAX_ZIP_BYTES {
		r.err = strings.concatenate({path, " is larger than 2 GB."}, context.allocator)
		r.hint = "That is not a Spotify export. Extract only the Streaming_History_Audio_*.json files and pass the folder."
		return
	}
	zip := new(Zip_Archive)
	zip.path = path
	zip.data = data
	if msg := parse_zip_directory(zip); len(msg) > 0 {
		r.err = strings.concatenate({path, ": ", msg}, context.allocator)
		r.hint = "The download may be incomplete. Download the export again, or extract it and pass the folder."
		return
	}
	for ze, i in zip.entries {
		if !zip_entry_is_candidate(ze.name) do continue
		append(&r.entries, Input_Entry{
			name = strings.concatenate({filepath.base(path), "!", ze.name}, context.allocator),
			archive = zip,
			entry = i,
		})
	}
}

// Only a .json file that is not resource-fork noise, with a path that cannot
// escape: we never write entries out, but a hostile name should never be shown
// or trusted either.
zip_entry_is_candidate :: proc(name: string) -> bool {
	if !safe_zip_name(name) do return false
	lower := strings.to_lower(name, context.temp_allocator)
	if !strings.has_suffix(lower, ".json") do return false
	if strings.has_prefix(lower, "__macosx/") || strings.contains(lower, "/__macosx/") do return false
	base := filepath.base(name)
	return !strings.has_prefix(base, ".")
}

safe_zip_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 512 do return false
	if name[0] == '/' || name[0] == '\\' do return false
	if len(name) > 1 && name[1] == ':' do return false
	for c in name {
		if c == 0 || c == '\\' do return false
	}
	parts := strings.split(name, "/", context.temp_allocator)
	for part in parts {
		if part == ".." do return false
	}
	return true
}

// Reads the central directory. Returns a message for anything unusable.
parse_zip_directory :: proc(z: ^Zip_Archive) -> string {
	b := z.data
	if len(b) < 22 do return "not a ZIP file (too small)"

	// The end-of-central-directory record is within the last 64 KB.
	eocd := -1
	lowest := max(0, len(b) - 22 - 65535)
	for i := len(b) - 22; i >= lowest; i -= 1 {
		if le32(b, i) == 0x06054b50 { eocd = i; break }
	}
	if eocd < 0 do return "not a ZIP file (no central directory)"

	count := int(le16(b, eocd + 10))
	cd_size := int(le32(b, eocd + 12))
	cd_off := int(le32(b, eocd + 16))
	if count == 0xFFFF || cd_size == -1 || u32(cd_off) == 0xFFFFFFFF {
		return "ZIP64 archives are not supported"
	}
	if count > MAX_ZIP_ENTRIES do return "too many entries in the archive"
	if cd_off < 0 || cd_off + cd_size > len(b) do return "damaged ZIP (central directory out of range)"

	off := cd_off
	total: u64
	for _ in 0..<count {
		if off + 46 > len(b) || le32(b, off) != 0x02014b50 do return "damaged ZIP (bad directory entry)"
		flags := le16(b, off + 8)
		method := le16(b, off + 10)
		comp := le32(b, off + 20)
		size := le32(b, off + 24)
		nlen := int(le16(b, off + 28))
		xlen := int(le16(b, off + 30))
		clen := int(le16(b, off + 32))
		lho := le32(b, off + 42)
		if off + 46 + nlen + xlen + clen > len(b) do return "damaged ZIP (entry runs past the end)"
		name := string(b[off + 46:off + 46 + nlen])
		off += 46 + nlen + xlen + clen

		if flags & 1 != 0 && zip_entry_is_candidate(name) do return "encrypted ZIPs are not supported"
		if !zip_entry_is_candidate(name) do continue

		if method != 0 && method != 8 do return "unsupported compression in ZIP"
		if int(size) > MAX_ENTRY_BYTES do return strings.concatenate({name, " is too large"}, context.temp_allocator)
		if comp > 0 && int(size) / int(comp) > MAX_EXPANSION_RATIO && size > 1 << 20 {
			return strings.concatenate({name, " has a suspicious compression ratio"}, context.temp_allocator)
		}
		total += u64(size)
		if total > MAX_EXPANDED_BYTES do return "the archive expands to more than 2 GB"
		append(&z.entries, Zip_Entry{strings.clone(name), method, comp, size, lho})
	}
	return ""
}

zip_entry_bytes :: proc(z: ^Zip_Archive, i: int) -> (data: []u8, err: string) {
	ze := z.entries[i]
	b := z.data
	lo := int(ze.local_offset)
	if lo < 0 || lo + 30 > len(b) || le32(b, lo) != 0x04034b50 do return nil, "damaged ZIP (bad local header)"
	start := lo + 30 + int(le16(b, lo + 26)) + int(le16(b, lo + 28))
	end := start + int(ze.comp_size)
	if start > len(b) || end > len(b) || end < start do return nil, "damaged ZIP (entry data out of range)"
	raw := b[start:end]

	if ze.method == 0 {
		if int(ze.comp_size) != int(ze.size) do return nil, "damaged ZIP (stored size mismatch)"
		return slice.clone(raw), "" // copy, so the caller can free every result alike
	}
	buf: bytes.Buffer
	if zerr := zlib.inflate_from_byte_array_raw(raw, &buf, raw = true, expected_output_size = int(ze.size)); zerr != nil {
		bytes.buffer_destroy(&buf)
		return nil, "damaged ZIP (could not decompress)"
	}
	out := bytes.buffer_to_bytes(&buf)
	if len(out) != int(ze.size) {
		bytes.buffer_destroy(&buf)
		return nil, "damaged ZIP (size does not match the directory)"
	}
	return out, ""
}

// ── Reading and recognising files ───────────────────────────────────────────

read_input :: proc(e: Input_Entry) -> (data: []u8, err: string) {
	if e.archive != nil do return zip_entry_bytes(e.archive, e.entry)
	d, rerr := os.read_entire_file(e.path, context.allocator)
	if rerr != nil do return nil, "could not be read"
	if len(d) > MAX_ENTRY_BYTES {
		delete(d)
		return nil, "is larger than 512 MB"
	}
	return d, ""
}

File_Kind :: enum {
	Streaming_History, // Extended Streaming History (ts, ms_played, …)
	Account_History,   // the one-year StreamingHistory*.json (endTime, msPlayed, …)
	Other,             // some other JSON in the package, or not an array at all
	Damaged,           // looks like streaming history but is not valid JSON
}

// What a parsed file is, judged by its content and not by its name.
classify_file :: proc(name: string, data: []u8) -> (kind: File_Kind, records: [dynamic]Streaming_Record) {
	// Cheap first look: only arrays of objects can be history. Skip a BOM and blanks.
	i := 0
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF do i = 3
	for i < len(data) && (data[i] == ' ' || data[i] == '\n' || data[i] == '\r' || data[i] == '\t') do i += 1
	if i >= len(data) || data[i] != '[' do return .Other, nil

	looks_named := strings.has_prefix(filepath.base(name), "Streaming_History_") ||
		strings.contains(filepath.base(name), "StreamingHistory")

	recs: [dynamic]Streaming_Record
	if err := json.unmarshal(data[i:], &recs); err != nil {
		delete(recs)
		return .Damaged if looks_named else .Other, nil
	}
	if len(recs) == 0 do return .Other, recs
	if len(recs[0].ts) > 0 do return .Streaming_History, recs

	// Not extended. Is it the short account-data format?
	Legacy :: struct { endTime: string, msPlayed: i64 }
	legacy: [dynamic]Legacy
	defer delete(legacy)
	if json.unmarshal(data[i:], &legacy) == nil && len(legacy) > 0 && len(legacy[0].endTime) > 0 {
		delete(recs)
		return .Account_History, nil
	}
	delete(recs)
	return .Other, nil
}

// 64-bit content fingerprint, to spot the same file given twice.
file_fingerprint :: proc(data: []u8) -> u64 {
	return hash.fnv64a(data)
}
