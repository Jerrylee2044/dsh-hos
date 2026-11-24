// DSH HOS libc++ ABI compatibility.
// Node is built against libc++ 22 headers with the __n1 ABI namespace, but the
// HarmonyOS SDK ships an older libc++_shared.so without __hash_memory.
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace std {
inline namespace __n1 {
size_t __hash_memory(const void* ptr, size_t size) noexcept {
  const size_t m = 0x5bd1e995;
  size_t h = 0x9747b28c ^ size;
  const char* p = static_cast<const char*>(ptr);
  size_t left = size;
  while (left >= 4) {
    uint32_t k = 0;
    std::memcpy(&k, p, 4);
    k *= m; k ^= k >> 24; k *= m;
    h ^= k; h *= m;
    p += 4; left -= 4;
  }
  switch (left) {
    case 3: h ^= static_cast<size_t>(static_cast<unsigned char>(p[2])) << 16; [[fallthrough]];
    case 2: h ^= static_cast<size_t>(static_cast<unsigned char>(p[1])) << 8; [[fallthrough]];
    case 1: h ^= static_cast<size_t>(static_cast<unsigned char>(p[0])); h *= m; break;
    default: break;
  }
  h ^= h >> 13; h *= m; h ^= h >> 15;
  return h;
}
}
}
