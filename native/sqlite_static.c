/*
 * The SQLite that the prebuilt db_sqlite links (built with -DDB_SQLITE_STATIC by .github/workflows/native-prebuilt.yml),
 * and its options. The amalgamation is not in the repository: tools/sqlite_amalgamation.py fetches the zip of the URL
 * below, checks it against the SHA3-256 that sqlite.org publishes, and puts sqlite3.c and sqlite3.h on the include
 * path. A build from source (the `build` table) never compiles this file. It is in native/, so a new pin or option
 * changes the source key of the prebuilt files.
 */
#define DB_SQLITE_AMALGAMATION_URL "https://sqlite.org/2026/sqlite-amalgamation-3540100.zip"
#define DB_SQLITE_AMALGAMATION_SHA3_256 "92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30"

/* No extension loading: the driver never loads one, and the library then needs no dlopen. */
#define SQLITE_OMIT_LOAD_EXTENSION 1
/* FTS5 and the math functions, which the system SQLite of Debian has too. */
#define SQLITE_ENABLE_FTS5 1
#define SQLITE_ENABLE_MATH_FUNCTIONS 1

#include "sqlite3.c"
