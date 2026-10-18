These plist fixtures are **synthetic schema examples**, not captures from a real disk or macOS 12.

The installed diskutil manual documents `list -plist`, `info -plist`, and `apfs list -plist`. Key spellings were checked against the installed diskutil binary; nesting and optional-field examples remain test assumptions requiring real-media capture during manual acceptance. Tests deliberately cover absent optional fields and report malformed required identity rather than inventing a volume UUID.
