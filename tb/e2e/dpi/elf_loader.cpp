#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <string>
#include <vector>

namespace {

struct Segment {
  std::uint64_t paddr = 0;
  std::uint64_t filesz = 0;
  std::uint64_t memsz = 0;
  std::vector<std::uint8_t> bytes;
};

struct HostConfig {
  int xlen = 0;
  int axi_data_width = 0;
  int axi_id_width = 0;
  std::uint64_t bootrom_base = 0;
  std::uint64_t bootrom_size = 0;
  std::uint64_t itim_base = 0;
  std::uint64_t itim_size = 0;
  std::uint64_t dtim_base = 0;
  std::uint64_t dtim_size = 0;
  std::uint64_t clint_base = 0;
  std::uint64_t plic_base = 0;
  std::uint64_t hostif_base = 0;
};

std::vector<std::uint8_t> g_file;
std::vector<Segment> g_segments;
std::uint64_t g_entry = 0;
std::string g_error;
HostConfig g_config;

template <typename T>
bool read_le(std::size_t offset, T* value) {
  if (offset > g_file.size() || sizeof(T) > g_file.size() - offset) {
    g_error = "ELF field extends beyond the file";
    return false;
  }
  T result = 0;
  for (std::size_t byte = 0; byte < sizeof(T); ++byte)
    result |= static_cast<T>(g_file[offset + byte]) << (byte * 8);
  *value = result;
  return true;
}

bool range_in_file(std::uint64_t offset, std::uint64_t size) {
  if (offset > std::numeric_limits<std::size_t>::max() ||
      size > std::numeric_limits<std::size_t>::max())
    return false;
  const auto local_offset = static_cast<std::size_t>(offset);
  const auto local_size = static_cast<std::size_t>(size);
  return local_offset <= g_file.size() && local_size <= g_file.size() - local_offset;
}

bool add_segment(std::uint64_t file_offset, std::uint64_t paddr,
                 std::uint64_t filesz, std::uint64_t memsz) {
  if (filesz > memsz) {
    g_error = "PT_LOAD filesz exceeds memsz";
    return false;
  }
  if (!range_in_file(file_offset, filesz)) {
    g_error = "PT_LOAD data extends beyond the ELF file";
    return false;
  }
  if (paddr > std::numeric_limits<std::uint64_t>::max() - memsz) {
    g_error = "PT_LOAD physical-address range wraps";
    return false;
  }
  Segment segment;
  segment.paddr = paddr;
  segment.filesz = filesz;
  segment.memsz = memsz;
  const auto first = g_file.begin() + static_cast<std::size_t>(file_offset);
  segment.bytes.assign(first, first + static_cast<std::size_t>(filesz));
  g_segments.push_back(std::move(segment));
  return true;
}

bool parse_elf32() {
  std::uint32_t entry = 0, phoff = 0;
  std::uint16_t phentsize = 0, phnum = 0;
  if (!read_le(24, &entry) || !read_le(28, &phoff) ||
      !read_le(42, &phentsize) || !read_le(44, &phnum))
    return false;
  if (phentsize < 32) {
    g_error = "ELF32 program-header entry is too small";
    return false;
  }
  g_entry = entry;
  for (std::uint16_t index = 0; index < phnum; ++index) {
    const std::uint64_t base = static_cast<std::uint64_t>(phoff) +
                               static_cast<std::uint64_t>(index) * phentsize;
    std::uint32_t type = 0, offset = 0, paddr = 0, filesz = 0, memsz = 0;
    if (!read_le(base + 0, &type) || !read_le(base + 4, &offset) ||
        !read_le(base + 12, &paddr) || !read_le(base + 16, &filesz) ||
        !read_le(base + 20, &memsz))
      return false;
    if (type == 1 && !add_segment(offset, paddr, filesz, memsz))
      return false;
  }
  return true;
}

bool parse_elf64() {
  std::uint64_t entry = 0, phoff = 0;
  std::uint16_t phentsize = 0, phnum = 0;
  if (!read_le(24, &entry) || !read_le(32, &phoff) ||
      !read_le(54, &phentsize) || !read_le(56, &phnum))
    return false;
  if (phentsize < 56) {
    g_error = "ELF64 program-header entry is too small";
    return false;
  }
  g_entry = entry;
  for (std::uint16_t index = 0; index < phnum; ++index) {
    const std::uint64_t base = phoff + static_cast<std::uint64_t>(index) * phentsize;
    std::uint32_t type = 0;
    std::uint64_t offset = 0, paddr = 0, filesz = 0, memsz = 0;
    if (!read_le(base + 0, &type) || !read_le(base + 8, &offset) ||
        !read_le(base + 24, &paddr) || !read_le(base + 32, &filesz) ||
        !read_le(base + 40, &memsz))
      return false;
    if (type == 1 && !add_segment(offset, paddr, filesz, memsz))
      return false;
  }
  return true;
}

}  // namespace

extern "C" void host_config(
    int xlen, int axi_data_width, int axi_id_width,
    unsigned long long bootrom_base, unsigned long long bootrom_size,
    unsigned long long itim_base, unsigned long long itim_size,
    unsigned long long dtim_base, unsigned long long dtim_size,
    unsigned long long clint_base, unsigned long long plic_base,
    unsigned long long hostif_base) {
  g_config = {xlen, axi_data_width, axi_id_width,
              bootrom_base, bootrom_size, itim_base, itim_size,
              dtim_base, dtim_size, clint_base, plic_base, hostif_base};
}

extern "C" int host_open_elf(const char* path) {
  g_file.clear();
  g_segments.clear();
  g_entry = 0;
  g_error.clear();
  if (path == nullptr || *path == '\0') {
    g_error = "ELF path is empty";
    return 0;
  }
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    g_error = std::string("cannot open ELF: ") + path;
    return 0;
  }
  g_file.assign(std::istreambuf_iterator<char>(input),
                std::istreambuf_iterator<char>());
  if (g_file.size() < 64 || g_file[0] != 0x7f || g_file[1] != 'E' ||
      g_file[2] != 'L' || g_file[3] != 'F') {
    g_error = "input is not an ELF image";
    return 0;
  }
  if (g_file[5] != 1) {
    g_error = "only little-endian ELF images are supported";
    return 0;
  }
  std::uint16_t machine = 0;
  if (!read_le(18, &machine) || machine != 243) {
    g_error = "ELF machine is not RISC-V";
    return 0;
  }
  bool parsed = false;
  if (g_file[4] == 1)
    parsed = parse_elf32();
  else if (g_file[4] == 2)
    parsed = parse_elf64();
  else
    g_error = "unsupported ELF class";
  if (!parsed)
    return 0;
  if (g_segments.empty()) {
    g_error = "ELF contains no PT_LOAD segment";
    return 0;
  }
  return 1;
}

extern "C" unsigned long long host_elf_entry() { return g_entry; }

extern "C" int host_segment_count() {
  return static_cast<int>(g_segments.size());
}

extern "C" unsigned long long host_segment_paddr(int index) {
  if (index < 0 || static_cast<std::size_t>(index) >= g_segments.size())
    return 0;
  return g_segments[static_cast<std::size_t>(index)].paddr;
}

extern "C" unsigned long long host_segment_filesz(int index) {
  if (index < 0 || static_cast<std::size_t>(index) >= g_segments.size())
    return 0;
  return g_segments[static_cast<std::size_t>(index)].filesz;
}

extern "C" unsigned long long host_segment_memsz(int index) {
  if (index < 0 || static_cast<std::size_t>(index) >= g_segments.size())
    return 0;
  return g_segments[static_cast<std::size_t>(index)].memsz;
}

extern "C" int host_segment_byte(int index, unsigned long long offset) {
  if (index < 0 || static_cast<std::size_t>(index) >= g_segments.size())
    return 0;
  const auto& segment = g_segments[static_cast<std::size_t>(index)];
  if (offset >= segment.filesz)
    return 0;
  return segment.bytes[static_cast<std::size_t>(offset)];
}

extern "C" const char* host_last_error() { return g_error.c_str(); }

extern "C" int host_poll_rx() { return -1; }

extern "C" void host_event(int kind, unsigned int data) {
  if (kind == 2)
    std::fputc(static_cast<int>(data & 0xffu), stdout);
  else
    std::fprintf(stdout, "[host-event kind=%d data=0x%08x]\n", kind, data);
  std::fflush(stdout);
}

extern "C" void host_finish(int code) {
  std::fprintf(stdout, "[host-finish code=%d]\n", code);
  std::fflush(stdout);
}
