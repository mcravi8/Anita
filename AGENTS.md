# Buddy installation

- Keep exactly one user-facing Buddy application: `/Applications/Buddy.app`, bundle identifier `app.buddy.desktop`.
- Update that same application. Never leave a loose `Buddy.app` in `outputs`, a versioned backup app, or a separate “Check”, “Setup”, or other test application.
- Build with `python3 outputs/buddy-mac/build.py --install`. Temporary staging must be inside `.noindex` directories and removed afterward. Keep packages and rollback backups as ZIP archives only.
- Use command-line fixtures for automated tests and the existing installed application for visual checks. Do not create additional app identities for testing.
- Preserve the user's Application Support data, agents, chats, connected folders, browser profiles, and Keychain credentials during updates and cleanup.
