// DSH HOS self-developed Node entry.
//
// The host loads libnode.so with dlopen() and calls this C entry. It only
// translates argv/env into node::Start(); no IEC path/tty/exec shims are used
// because DSH HOS runs Node in its own fork child with real sandbox paths.
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <dlfcn.h>

namespace node {
int Start(int argc, char* argv[]);
}

static bool WantJitless() {
  const char* value = getenv("DSH_NODE_JITLESS");
  if (value != nullptr && strcmp(value, "off") == 0) { return false; }
  return true;
}

extern "C" int dsh_node_main(int argc, char** argv) {
  const char* libnode = getenv("DSH_LIBNODE");
  if (libnode != nullptr && *libnode != 0) { dlopen(libnode, RTLD_NOW | RTLD_GLOBAL); }
  std::vector<std::string> parts;
  std::vector<char*> av;
  parts.push_back("node");
  if (WantJitless()) {
    parts.push_back("--jitless");
  }
  parts.push_back("--expose-internals");
  for (int i = 1; i < argc; ++i) {
    parts.push_back(argv[i] == nullptr ? "" : argv[i]);
  }
  size_t total = 0;
  for (const std::string& item : parts) { total += item.size() + 1; }
  std::vector<char> block(total, '\0');
  size_t offset = 0;
  for (const std::string& item : parts) {
    av.push_back(&block[offset]);
    if (!item.empty()) { memcpy(&block[offset], item.data(), item.size()); }
    offset += item.size() + 1;
  }
  av.push_back(nullptr);
  return node::Start(static_cast<int>(av.size() - 1), av.data());
}
