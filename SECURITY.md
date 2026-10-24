# Security Policy

## Supported versions

sb-shot has no tagged releases yet. Security fixes are made on the `main` branch only; please make sure you can reproduce the issue on the latest `main` before reporting it.

| Version | Supported |
|---|---|
| `main` (latest commit) | Yes |
| Older commits and forks | No |

Once versioned releases are published, only the latest release will receive security fixes.

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues, discussions or pull requests.**

Report them privately through GitHub Security Advisories:

1. Go to the [Security tab](https://github.com/Osmait/sb-shot/security) of the repository.
2. Click **Report a vulnerability**.
3. Fill in the form with as much detail as you can:
   - the type of issue (for example: sandbox escape, unintended file access, leaking captured content, insecure handling of the clipboard or temporary files),
   - the affected files or features,
   - step-by-step instructions to reproduce it,
   - your macOS version and the commit you built from,
   - the impact, and a proof of concept if you have one.

You can expect an acknowledgement within 7 days. We will keep you informed while we investigate and fix the issue, and credit you in the advisory unless you prefer to remain anonymous. Please give us reasonable time to release a fix before disclosing the issue publicly.

## Scope

sb-shot is a sandboxed app that handles screen contents, audio and files chosen by the user. Issues of particular interest include:

- access to files or folders beyond the sandbox entitlements and the folders the user selected,
- captured images or recordings being stored or exposed somewhere the user did not expect,
- the app capturing content without a user action or without the Screen Recording permission.

Problems in macOS itself or in Apple frameworks should be reported to Apple.
