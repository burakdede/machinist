# JVM toolchain

[← back to README](../README.md)

## JVM toolchain

**SDKMAN owns everything JVM. mise owns everything else.** That split is
deliberate, and the reason is narrow: mise can install Java, Maven, Gradle,
Kotlin, Scala and sbt perfectly well, but it **cannot** install GraalVM, the
Spring Boot CLI, or VisualVM. Since those are needed, SDKMAN stays, and mise is
kept out of the JVM entirely so the two never shadow each other on PATH.

Candidates live in [`packages/sdkman.txt`](../packages/sdkman.txt), shared by
both machines. The format is `candidate[@version]`; omit the version to track
SDKMAN's current default.

### GraalVM is a java distribution, not a candidate

There is no `graalvm` candidate. GraalVM is installed as another `java` entry:

```
java@25.0.4-tem       # default JDK
java@25.2.4-graalce   # GraalVM CE, installed alongside
```

Multiple `java` lines install multiple JDKs side by side. The **first** one
becomes the default and is what `JAVA_HOME` points at; the rest sit next to it.

### What the setup wires up beyond installing

SDKMAN only puts binaries on PATH. These are set by [`dotfiles/.zshrc`](../dotfiles/.zshrc):

| Variable | Points at | Why |
|---|---|---|
| `JAVA_HOME` | `candidates/java/current` | Gradle, Maven and jdtls read it instead of searching PATH |
| `GRAALVM_HOME` | the highest-versioned `*-graal*` install | Deliberately *not* `current`, since GraalVM is the secondary JDK |
| `MAVEN_HOME` | `candidates/maven/current` | Unused by Maven itself since 3.5, still read by some IDEs |
| `fpath` += | `springboot/.../shell-completion/zsh` | The Spring Boot CLI ships a completion but never installs it |

The `sdk` step reports each of these at the end, and warns if `mvn` or `gradle`
resolve somewhere other than SDKMAN.

### Do not install Maven or Gradle from Homebrew or APT

Whichever copy comes first on PATH wins, and it will not be SDKMAN's. This
setup keeps Maven and Gradle under SDKMAN. The platform setup lives in
[`mac/sdk/sdk.sh`](../mac/sdk/sdk.sh) and
[`linux/sdk/sdk.sh`](../linux/sdk/sdk.sh). It warns if Maven or Gradle resolve
outside SDKMAN.

### Switching versions

```bash
sdk list java              # available identifiers
sdk install java 21.0.5-tem
sdk default java 21.0.5-tem   # change the default, and JAVA_HOME with it
sdk use java 25.2.4-graalce   # this shell only
```
