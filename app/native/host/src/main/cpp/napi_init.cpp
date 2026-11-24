#include <napi/native_api.h>
#include <hilog/log.h>
#include <dlfcn.h>
#include <zlib.h>
#include <sys/stat.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#include <map>
#include <mutex>
#include <string>
#include <filesystem>
#include <dirent.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <vector>
#include <thread>
#include <atomic>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#ifndef DSH_HOST_API
#define DSH_HOST_API 2
#endif

typedef int (*HostEntry)(int, char **, char **);

struct HostJob {
  pid_t pid = -1;
  int inFd = -1;
  int outFd = -1;
  int errFd = -1;
  bool running = true;
  int code = -1;
  std::string out;
  std::string err;
};

static std::mutex gLock;
static std::map<int, HostJob *> gJobs;
static int gNext = 1;

static std::string GetString(napi_env env, napi_value value) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) { return std::string(); }
  std::vector<char> buffer(length + 1);
  if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length) != napi_ok) {
    return std::string();
  }
  return std::string(buffer.data(), length);
}

static bool GetStringArray(napi_env env, napi_value value, std::vector<std::string> &out) {
  uint32_t length = 0;
  if (napi_get_array_length(env, value, &length) != napi_ok) { return false; }
  for (uint32_t i = 0; i < length; ++i) {
    napi_value item;
    if (napi_get_element(env, value, i, &item) != napi_ok) { return false; }
    out.push_back(GetString(env, item));
  }
  return true;
}

static napi_value SetInt(napi_env env, napi_value obj, const char *name, int value) {
  napi_value item;
  napi_create_int32(env, value, &item);
  napi_set_named_property(env, obj, name, item);
  return obj;
}

static napi_value SetBool(napi_env env, napi_value obj, const char *name, bool value) {
  napi_value item;
  napi_get_boolean(env, value, &item);
  napi_set_named_property(env, obj, name, item);
  return obj;
}

static napi_value SetString(napi_env env, napi_value obj, const char *name, const std::string &value) {
  napi_value item;
  napi_create_string_utf8(env, value.c_str(), value.size(), &item);
  napi_set_named_property(env, obj, name, item);
  return obj;
}


static uint64_t TarNumber(const char *field, size_t length) {
  char buffer[32] = {0};
  size_t n = length < sizeof(buffer) - 1 ? length : sizeof(buffer) - 1;
  size_t start = 0;
  while (start < n && (field[start] == ' ' || field[start] == '\0')) { ++start; }
  memcpy(buffer, field + start, n - start);
  return static_cast<uint64_t>(strtoull(buffer, nullptr, 8));
}

static bool MakeDirs(const std::string &path) {
  std::string current;
  size_t start = 0;
  if (!path.empty() && path[0] == '/') { current = "/"; start = 1; }
  while (start <= path.size()) {
    size_t slash = path.find('/', start);
    std::string part = path.substr(start, slash == std::string::npos ? std::string::npos : slash - start);
    if (!part.empty()) {
      if (!current.empty() && current.back() != '/') { current.push_back('/'); }
      current += part;
      if (mkdir(current.c_str(), 0755) != 0 && errno != EEXIST) { return false; }
    }
    if (slash == std::string::npos) { break; }
    start = slash + 1;
  }
  return true;
}

static bool SafeTarget(const std::string &root, const std::string &name, std::string &out) {
  if (name.empty()) { return false; }
  std::string base = root;
  if (!base.empty() && base.back() == '/') { base.pop_back(); }
  std::string candidate = name;
  while (!candidate.empty() && candidate[0] == '/') { candidate.erase(candidate.begin()); }
  if (candidate.find("..") != std::string::npos) { return false; }
  out = base + "/" + candidate;
  return true;
}

static bool WriteChunk(gzFile file, const std::string &path, uint64_t size, mode_t mode) {
  std::string parent = path.substr(0, path.find_last_of('/'));
  if (!parent.empty() && !MakeDirs(parent)) { return false; }
  int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, mode == 0 ? 0644 : mode);
  if (fd < 0) { return false; }
  char buffer[65536];
  uint64_t left = size;
  while (left > 0) {
    size_t want = left > sizeof(buffer) ? sizeof(buffer) : static_cast<size_t>(left);
    int got = gzread(file, buffer, static_cast<unsigned>(want));
    if (got <= 0) { close(fd); return false; }
    size_t written = 0;
    while (written < static_cast<size_t>(got)) {
      ssize_t n = write(fd, buffer + written, static_cast<size_t>(got) - written);
      if (n <= 0) { close(fd); return false; }
      written += static_cast<size_t>(n);
    }
    left -= static_cast<uint64_t>(got);
  }
  close(fd);
  return true;
}

static int UnpackArchive(const std::string &archive, const std::string &destination) {
  gzFile file = gzopen(archive.c_str(), "rb");
  if (file == nullptr) { return 1; }
  if (!MakeDirs(destination)) { gzclose(file); return 2; }
  std::string longName;
  std::string paxName;
  uint64_t paxSize = 0;
  bool hasPaxSize = false;
  char header[512];
  int result = 0;
  for (;;) {
    int got = gzread(file, header, sizeof(header));
    if (got == 0) { break; }
    if (got != sizeof(header)) { result = 3; break; }
    bool empty = true;
    for (char c : header) { if (c != 0) { empty = false; break; } }
    if (empty) { break; }
    std::string name(header, strnlen(header, 100));
    if (header[345] != 0) {
      std::string prefix(header + 345, strnlen(header + 345, 155));
      if (!prefix.empty()) { name = prefix + "/" + name; }
    }
    if (!longName.empty()) { name = longName; }
    if (!paxName.empty()) { name = paxName; }
    uint64_t size = hasPaxSize ? paxSize : TarNumber(header + 124, 12);
    hasPaxSize = false;
    paxName.clear();
    char type = header[156];
    mode_t mode = static_cast<mode_t>(TarNumber(header + 100, 8));
    if (type == 'x' || type == 'g') {
      std::string payload(size, '\0');
      if (gzread(file, payload.data(), static_cast<unsigned>(size)) != static_cast<int>(size)) { result = 4; break; }
      size_t pos = 0;
      while (pos < payload.size()) {
        size_t space = payload.find(' ', pos);
        if (space == std::string::npos) { break; }
        size_t equal = payload.find('=', space + 1);
        if (equal == std::string::npos) { break; }
        std::string key = payload.substr(pos, space - pos);
        size_t length = static_cast<size_t>(strtoull(payload.substr(space + 1, equal - space - 1).c_str(), nullptr, 10));
        std::string value = payload.substr(equal + 1, length);
        if (key == "path") { paxName = value; }
        if (key == "size") { paxSize = strtoull(value.c_str(), nullptr, 10); hasPaxSize = true; }
        pos = equal + 1 + length;
        if (pos < payload.size() && payload[pos] == '\n') { ++pos; }
      }
      uint64_t padding = (512 - (size % 512)) % 512;
      if (padding > 0) { std::vector<char> skip(padding); gzread(file, skip.data(), static_cast<unsigned>(padding)); }
      continue;
    }
    if (type == 'L') {
      char buffer[512];
      std::string value;
      uint64_t left = size;
      while (left > 0) {
        int n = gzread(file, buffer, left > 512 ? 512 : static_cast<unsigned>(left));
        if (n <= 0) { result = 5; break; }
        value.append(buffer, static_cast<size_t>(n));
        left -= static_cast<uint64_t>(n);
      }
      longName = value;
      size_t zero = longName.find('\0');
      if (zero != std::string::npos) { longName.resize(zero); }
      uint64_t padding = (512 - (size % 512)) % 512;
      if (padding > 0) { std::vector<char> skip(padding); gzread(file, skip.data(), static_cast<unsigned>(padding)); }
      continue;
    }
    std::string target;
    if (!SafeTarget(destination, name, target)) { result = 6; break; }
    bool skipData = type == '5' || type == '1';
    if (type == '5') {
      if (!MakeDirs(target)) { result = 7; break; }
    } else if (type == '0' || type == '\0') {
      if (!longName.empty() || !paxName.empty()) { name = ""; }
      if (!WriteChunk(file, target, size, mode)) { result = 8; break; }
      skipData = true;
    } else if (type == '2') {
      std::string link(header + 157, strnlen(header + 157, 100));
      if (!MakeDirs(target.substr(0, target.find_last_of('/')))) { result = 9; break; }
      symlink(link.c_str(), target.c_str());
      skipData = true;
    }
    uint64_t padding = (512 - (size % 512)) % 512;
    if (!skipData) {
      char buffer[512];
      uint64_t left = size;
      while (left > 0) {
        int n = gzread(file, buffer, left > 512 ? 512 : static_cast<unsigned>(left));
        if (n <= 0) { result = 10; break; }
        left -= static_cast<uint64_t>(n);
      }
    }
    if (padding > 0) {
      std::vector<char> skip(padding);
      gzread(file, skip.data(), static_cast<unsigned>(padding));
    }
    longName.clear();
  }
  gzclose(file);
  return result;
}


static napi_value TestAddon(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value callArgs[2];
  napi_get_cb_info(env, info, &argc, callArgs, nullptr, nullptr);
  if (argc < 2) { napi_throw_error(env, nullptr, "testAddon expects libnode and addon"); return nullptr; }
  std::string libnode = GetString(env, callArgs[0]);
  std::string addon = GetString(env, callArgs[1]);
  std::string result;
  void* node = dlopen(libnode.c_str(), RTLD_NOW | RTLD_GLOBAL);
  if (node == nullptr) { result = std::string("libnode: ") + dlerror(); }
  else {
    void* h = dlopen(addon.c_str(), RTLD_NOW | RTLD_GLOBAL);
    const char* err = dlerror();
    result = h == nullptr ? (err == nullptr ? "addon: unknown" : std::string("addon: ") + err) : "ok";
    if (h != nullptr) { dlclose(h); }
  }
  napi_value out;
  napi_create_string_utf8(env, result.c_str(), result.size(), &out);
  return out;
}

static napi_value Symlink(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value callArgs[2];
  napi_get_cb_info(env, info, &argc, callArgs, nullptr, nullptr);
  napi_value result;
  bool ok = false;
  if (argc >= 2) {
    std::string target = GetString(env, callArgs[0]);
    std::string link = GetString(env, callArgs[1]);
    ok = symlink(target.c_str(), link.c_str()) == 0;
  }
  napi_get_boolean(env, ok, &result);
  return result;
}

static bool CopyDirRecursive(const std::string &src, const std::string &dst) {
  struct stat st;
  if (stat(src.c_str(), &st) != 0) { return false; }
  if (S_ISDIR(st.st_mode)) {
    if (mkdir(dst.c_str(), 0777) != 0 && errno != EEXIST) { return false; }
    DIR *dir = opendir(src.c_str());
    if (dir == nullptr) { return false; }
    struct dirent *entry;
    bool ok = true;
    while ((entry = readdir(dir)) != nullptr) {
      if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) { continue; }
      if (!CopyDirRecursive(src + "/" + entry->d_name, dst + "/" + entry->d_name)) { ok = false; break; }
    }
    closedir(dir);
    return ok;
  }
  int in = open(src.c_str(), O_RDONLY);
  if (in < 0) { return false; }
  int out = open(dst.c_str(), O_WRONLY | O_CREAT | O_TRUNC, st.st_mode & 0777);
  if (out < 0) { close(in); return false; }
  char buffer[65536];
  ssize_t n;
  bool ok = true;
  while ((n = read(in, buffer, sizeof(buffer))) > 0) {
    ssize_t written = 0;
    while (written < n) {
      ssize_t w = write(out, buffer + written, n - written);
      if (w <= 0) { ok = false; break; }
      written += w;
    }
    if (!ok) { break; }
  }
  close(in);
  close(out);
  return ok;
}

static napi_value CopyTree(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value callArgs[2];
  napi_get_cb_info(env, info, &argc, callArgs, nullptr, nullptr);
  bool ok = false;
  if (argc >= 2) {
    std::string src = GetString(env, callArgs[0]);
    std::string dst = GetString(env, callArgs[1]);
    ok = CopyDirRecursive(src, dst);
  }
  napi_value result;
  napi_get_boolean(env, ok, &result);
  return result;
}

static napi_value Unpack(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    napi_throw_error(env, nullptr, "unpack expects archive and destination");
    return nullptr;
  }
  std::string archive = GetString(env, args[0]);
  std::string destination = GetString(env, args[1]);
  int result = UnpackArchive(archive, destination);
  napi_value out;
  napi_create_int32(env, result, &out);
  return out;
}


struct ToolMap { const char *name; const char *library; const char *entry; };
static const ToolMap kHostTools[] = {
  {"git", "libgit.so", "iec_git_main"},
  {"git-remote-http", "libgit-remote-http.so", "iec_git_remote_http_main"},
  {"git-remote-https", "libgit-remote-http.so", "iec_git_remote_http_main"},
  {"git-lfs", "libgitlfscmd.so", "iec_gitlfs_main"},
  {"python", "libpython.so", "Py_BytesMain"},
  {"python3", "libpython.so", "Py_BytesMain"},
  {"pip", "libpython.so", "iec_pip_main"},
  {"rg", "librg.so", "iec_rg_main"},
  {"tar", "libbsdtar.so", "iec_bsdtar_main"},
  {"unzip", "libbsdunzip.so", "iec_bsdunzip_main"},
  {"zip", "libzipcmd.so", "iec_zip_main"},
  {"curl", "libcurlcmd.so", "iec_curl_main"},
  {"jq", "libjqcmd.so", "iec_jq_main"},
  {"ssh", "libdropbear.so", "iec_dropbear_main"},
  {"scp", "libdropbear.so", "iec_dropbear_main"},
  {"openssl", "libopensslcmd.so", "iec_openssl_main"},
  {"tree", "libtreecmd.so", "iec_tree_main"},
  {"sqlite3", "libsqlite3cmd.so", "iec_sqlite3_main"},
  {"rsync", "librsynccmd.so", "iec_rsync_main"},
  {"xz", "libxzcmd.so", "iec_xz_main"},
  {"zstd", "libzstdcmd.so", "iec_zstd_main"},
};

static const char* ToolLibFor(const std::string& name, std::string& entry, std::string& lib) {
  for (const auto& tool : kHostTools) {
    if (name == tool.name) { lib = tool.library; entry = tool.entry; return tool.name; }
  }
  return nullptr;
}

static void ServeToolClient(int client) {
  std::string request;
  char buffer[4096];
  while (request.find("\n\n") == std::string::npos) {
    ssize_t n = read(client, buffer, sizeof(buffer));
    if (n <= 0) { close(client); return; }
    request.append(buffer, static_cast<size_t>(n));
    if (request.size() > 1024 * 1024) { close(client); return; }
  }
  size_t end = request.find("\n\n");
  std::string header = request.substr(0, end);
  std::vector<std::string> lines;
  size_t start = 0;
  while (start <= header.size()) {
    size_t next = header.find('\n', start);
    if (next == std::string::npos) { lines.push_back(header.substr(start)); break; }
    lines.push_back(header.substr(start, next - start));
    start = next + 1;
  }
  if (lines.empty() || lines[0].empty()) { close(client); return; }
  std::string command = lines[0];
  std::string lib;
  std::string entry;
  if (ToolLibFor(command, entry, lib) == nullptr) {
    std::string msg = "dsh-tool: unsupported command '" + command + "'\n";
    std::string resp = "127\n" + std::to_string(msg.size()) + "\n" + msg;
    write(client, resp.data(), resp.size());
    close(client);
    return;
  }
  std::vector<std::string> args;
  args.push_back(command);
  for (size_t i = 1; i < lines.size(); ++i) { args.push_back(lines[i]); }
  int outPipe[2]; int errPipe[2];
  if (pipe(outPipe) != 0 || pipe(errPipe) != 0) { close(client); return; }
  pid_t pid = fork();
  if (pid == 0) {
    dup2(outPipe[1], STDOUT_FILENO);
    dup2(errPipe[1], STDERR_FILENO);
    close(outPipe[0]); close(outPipe[1]);
    close(errPipe[0]); close(errPipe[1]);
    std::string path = "/data/storage/el1/bundle/libs/arm64/" + lib;
    void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (handle == nullptr) {
      const char* err = dlerror();
      const char* msg = err ? err : "dlopen failed";
      write(STDERR_FILENO, msg, strlen(msg));
      _exit(127);
    }
    int (*fn)(int, char**) = reinterpret_cast<int (*)(int, char**)>(dlsym(handle, entry.c_str()));
    if (fn == nullptr) { _exit(127); }
    std::vector<char*> argv;
    for (auto& arg : args) { argv.push_back(const_cast<char*>(arg.c_str())); }
    argv.push_back(nullptr);
    int code = fn(static_cast<int>(argv.size() - 1), argv.data());
    _exit(code);
  }
  close(outPipe[1]); close(errPipe[1]);
  std::string output;
  struct pollfd fds[2] = {{outPipe[0], POLLIN, 0}, {errPipe[0], POLLIN, 0}};
  int openFds = 2;
  while (openFds > 0) {
    int ready = poll(fds, 2, 1000);
    if (ready < 0) { break; }
    for (int i = 0; i < 2; ++i) {
      if (fds[i].fd < 0) { continue; }
      if ((fds[i].revents & (POLLIN | POLLHUP | POLLERR)) != 0) {
        ssize_t n = read(fds[i].fd, buffer, sizeof(buffer));
        if (n > 0) { output.append(buffer, static_cast<size_t>(n)); }
        else { close(fds[i].fd); fds[i].fd = -1; openFds--; }
      }
    }
  }
  int waitStatus = 0;
  waitpid(pid, &waitStatus, 0);
  int code = WIFEXITED(waitStatus) ? WEXITSTATUS(waitStatus) : 127;
  std::string response = std::to_string(code) + "\n" + std::to_string(output.size()) + "\n" + output;
  write(client, response.data(), response.size());
  close(client);
}

static void StartToolServerOnce() {
  static std::atomic<bool> started(false);
  bool expected = false;
  if (!started.compare_exchange_strong(expected, true)) { return; }
  std::thread([]() {
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) { return; }
    int reuse = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(47654);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(server, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0) { close(server); return; }
    if (listen(server, 8) != 0) { close(server); return; }
    for (;;) {
      int client = accept(server, nullptr, nullptr);
      if (client < 0) { continue; }
      std::thread(ServeToolClient, client).detach();
    }
  }).detach();
}

static napi_value Probe(napi_env env, napi_callback_info info) {
  StartToolServerOnce();
  napi_value result;
  napi_create_object(env, &result);
  SetInt(env, result, "api", DSH_HOST_API);
  SetInt(env, result, "abi", 64);
  SetInt(env, result, "pid", static_cast<int>(getpid()));
  return result;
}

static napi_value Spawn(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value callArgs[1];
  napi_get_cb_info(env, info, &argc, callArgs, nullptr, nullptr);
  if (argc < 1) { napi_throw_error(env, nullptr, "spawn expects a spec object"); return nullptr; }

  napi_value libraryValue;
  napi_value entryValue;
  napi_value argvValue;
  napi_value envValue;
  napi_value cwdValue;
  napi_get_named_property(env, callArgs[0], "library", &libraryValue);
  napi_get_named_property(env, callArgs[0], "entry", &entryValue);
  napi_get_named_property(env, callArgs[0], "argv", &argvValue);
  napi_get_named_property(env, callArgs[0], "env", &envValue);
  napi_get_named_property(env, callArgs[0], "cwd", &cwdValue);

  const std::string library = GetString(env, libraryValue);
  const std::string entryName = GetString(env, entryValue);
  const std::string cwd = GetString(env, cwdValue);
  std::vector<std::string> cmdArgs;
  std::vector<std::string> envs;
  if (!GetStringArray(env, argvValue, cmdArgs) || !GetStringArray(env, envValue, envs)) {
    napi_throw_error(env, nullptr, "argv/env must be string arrays");
    return nullptr;
  }

  // Native addons resolve libc++ symbols from the process global scope; make
  // libc++ itself global before loading libnode.
  dlopen("libc++_shared.so", RTLD_NOW | RTLD_GLOBAL);
  void *handle = dlopen(library.c_str(), RTLD_NOW | RTLD_GLOBAL);
  if (handle == nullptr) { napi_throw_error(env, nullptr, dlerror()); return nullptr; }
  HostEntry entry = reinterpret_cast<HostEntry>(dlsym(handle, entryName.c_str()));
  if (entry == nullptr) { napi_throw_error(env, nullptr, "entry symbol not found"); dlclose(handle); return nullptr; }

  std::vector<char *> argv;
  if (!cmdArgs.empty()) {
    argv.push_back(const_cast<char *>(cmdArgs[0].c_str()));
    for (size_t i = 1; i < cmdArgs.size(); ++i) { argv.push_back(const_cast<char *>(cmdArgs[i].c_str())); }
  } else {
    argv.push_back(const_cast<char *>(entryName.c_str()));
  }
  argv.push_back(nullptr);
  std::vector<char *> envp;
  for (const auto &item : envs) { envp.push_back(const_cast<char *>(item.c_str())); }
  envp.push_back(nullptr);

  int inPipe[2];
  int outPipe[2];
  int errPipe[2];
  if (pipe(inPipe) != 0 || pipe(outPipe) != 0 || pipe(errPipe) != 0) {
    napi_throw_error(env, nullptr, "pipe failed");
    return nullptr;
  }

  pid_t pid = fork();
  if (pid < 0) {
    napi_throw_error(env, nullptr, "fork failed");
    return nullptr;
  }
  if (pid == 0) {
    setpgid(0, 0);
    dup2(inPipe[0], STDIN_FILENO);
    dup2(outPipe[1], STDOUT_FILENO);
    dup2(errPipe[1], STDERR_FILENO);
    close(inPipe[0]); close(inPipe[1]);
    close(outPipe[0]); close(outPipe[1]);
    close(errPipe[0]); close(errPipe[1]);
    if (!cwd.empty()) { chdir(cwd.c_str()); }
    // 以库入口方式启动时不会经过 execve，全局 environ 仍是应用进程的环境；
    // 必须显式替换，否则 Node 的 os.homedir() 会去读系统用户目录。
    environ = envp.data();
    int code = entry(static_cast<int>(argv.size() - 1), argv.data(), envp.data());
    _exit(code);
  }

  close(inPipe[0]);
  close(outPipe[1]);
  close(errPipe[1]);
  fcntl(inPipe[1], F_SETFL, fcntl(inPipe[1], F_GETFL) | O_NONBLOCK);
  fcntl(outPipe[0], F_SETFL, fcntl(outPipe[0], F_GETFL) | O_NONBLOCK);
  fcntl(errPipe[0], F_SETFL, fcntl(errPipe[0], F_GETFL) | O_NONBLOCK);

  HostJob *job = new HostJob();
  job->pid = pid;
  job->inFd = inPipe[1];
  job->outFd = outPipe[0];
  job->errFd = errPipe[0];

  int id;
  {
    std::lock_guard<std::mutex> guard(gLock);
    id = gNext++;
    gJobs[id] = job;
  }
  napi_value result;
  napi_create_int32(env, id, &result);
  return result;
}

static void Drain(int fd, std::string &out) {
  char buffer[8192];
  for (;;) {
    ssize_t n = read(fd, buffer, sizeof(buffer));
    if (n > 0) { out.append(buffer, static_cast<size_t>(n)); continue; }
    break;
  }
}

static napi_value Poll(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t id = 0;
  if (argc < 1 || napi_get_value_int32(env, args[0], &id) != napi_ok) {
    napi_throw_error(env, nullptr, "poll expects a job id");
    return nullptr;
  }
  HostJob *job = nullptr;
  {
    std::lock_guard<std::mutex> guard(gLock);
    auto it = gJobs.find(id);
    if (it != gJobs.end()) { job = it->second; }
  }
  if (job == nullptr) { napi_throw_error(env, nullptr, "job not found"); return nullptr; }

  napi_value result;
  napi_create_object(env, &result);
  if (!job->running) {
    SetString(env, result, "out", "");
    SetString(env, result, "err", "");
    SetBool(env, result, "running", false);
    SetBool(env, result, "outEof", true);
    SetBool(env, result, "errEof", true);
    SetInt(env, result, "code", job->code);
    return result;
  }

  std::string out;
  std::string err;
  Drain(job->outFd, out);
  Drain(job->errFd, err);

  int status = 0;
  pid_t done = waitpid(job->pid, &status, WNOHANG);
  bool running = true;
  if (done == job->pid) {
    running = false;
    job->running = false;
    job->code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    close(job->outFd); job->outFd = -1;
    close(job->errFd); job->errFd = -1;
    close(job->inFd); job->inFd = -1;
  }
  SetString(env, result, "out", out);
  SetString(env, result, "err", err);
  SetBool(env, result, "running", running);
  SetBool(env, result, "outEof", !running);
  SetBool(env, result, "errEof", !running);
  SetInt(env, result, "code", job->code);
  return result;
}

static napi_value Write(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t id = 0;
  if (argc < 2 || napi_get_value_int32(env, args[0], &id) != napi_ok) {
    napi_throw_error(env, nullptr, "write expects id and string");
    return nullptr;
  }
  std::string data = GetString(env, args[1]);
  HostJob *job = nullptr;
  {
    std::lock_guard<std::mutex> guard(gLock);
    auto it = gJobs.find(id);
    if (it != gJobs.end()) { job = it->second; }
  }
  int written = -1;
  if (job != nullptr && job->inFd >= 0) {
    ssize_t n = write(job->inFd, data.data(), data.size());
    written = static_cast<int>(n);
  }
  napi_value result;
  napi_create_int32(env, written, &result);
  return result;
}

static napi_value Terminate(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t id = 0;
  if (argc < 1 || napi_get_value_int32(env, args[0], &id) != napi_ok) {
    napi_throw_error(env, nullptr, "terminate expects id");
    return nullptr;
  }
  HostJob *job = nullptr;
  {
    std::lock_guard<std::mutex> guard(gLock);
    auto it = gJobs.find(id);
    if (it != gJobs.end()) { job = it->second; }
  }
  bool ok = false;
  if (job != nullptr && job->running) {
    ok = kill(job->pid, SIGTERM) == 0;
  }
  napi_value result;
  napi_get_boolean(env, ok, &result);
  return result;
}

static napi_value Release(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t id = 0;
  if (argc < 1 || napi_get_value_int32(env, args[0], &id) != napi_ok) {
    napi_throw_error(env, nullptr, "release expects id");
    return nullptr;
  }
  HostJob *job = nullptr;
  {
    std::lock_guard<std::mutex> guard(gLock);
    auto it = gJobs.find(id);
    if (it != gJobs.end()) { job = it->second; gJobs.erase(it); }
  }
  if (job != nullptr) {
    if (job->inFd >= 0) { close(job->inFd); }
    if (job->outFd >= 0) { close(job->outFd); }
    if (job->errFd >= 0) { close(job->errFd); }
    delete job;
  }
  return nullptr;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
    {"probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"unpack", nullptr, Unpack, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"copyTree", nullptr, CopyTree, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"symlink", nullptr, Symlink, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"testAddon", nullptr, TestAddon, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"spawn", nullptr, Spawn, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"poll", nullptr, Poll, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"write", nullptr, Write, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"terminate", nullptr, Terminate, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr}
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module hostModule = {
  1, 0, nullptr, Init, "dsh_host", nullptr, {0},
};

extern "C" __attribute__((constructor)) void RegisterHostModule(void) {
  napi_module_register(&hostModule);
}
