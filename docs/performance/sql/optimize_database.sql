-- ============================================================================
--  CSNZ_Server.exe -- SQLite database tuning script
-- ============================================================================
--
--  Run this ONCE while the server is stopped (make a backup of
--  UserDatabase.db3 first -- simply copy the file somewhere safe).
--
--  How to run (pick one):
--    * sqlite3.exe UserDatabase.db3 ".read optimize_database.sql"
--    * DB Browser for SQLite -> "Execute SQL" tab -> paste this file -> run
--    * python -c "import sqlite3;sqlite3.connect('UserDatabase.db3').executescript(open('optimize_database.sql').read())"
--
--  What it does:
--    1. Switches the database to WAL journal mode. This setting is *persistent*
--       (it is written into the database header), so the server will keep using
--       WAL after a restart even though the server source never sets it.
--       WAL removes the "create journal file -> write -> delete journal file"
--       cycle that SQLite currently performs on every single statement.
--    2. Adds the secondary indexes that the schema is missing. The schema only
--       has PRIMARY KEY / UNIQUE indexes, so the server's per-user queries
--       (inventory, loadout, quests, ...) and its per-minute expiry scans were
--       doing full table scans.
--    3. Refreshes the query planner statistics (ANALYZE) and compacts the file
--       (VACUUM).
--
--  Notes:
--    * The server opens the DB with "PRAGMA synchronous=OFF" (fast, but a power
--      loss / crash can corrupt the database) and "foreign_keys=ON".
--    * After this script the DB directory will also contain
--      UserDatabase.db3-wal and UserDatabase.db3-shm. Do not delete them while
--      the server is running, and always copy *all three* files when backing up
--      a WAL database (or use "VACUUM INTO 'backup.db3'").
--    * If you already applied patch 0005 (server creates these indexes itself),
--      running this script is harmless -- everything is "IF NOT EXISTS".
-- ============================================================================

PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;   -- only affects this connection; the server sets OFF itself
PRAGMA temp_store   = MEMORY;
PRAGMA cache_size   = -65536;   -- 64 MB page cache
PRAGMA mmap_size    = 268435456;-- 256 MB memory map

-- ---------------------------------------------------------------- user tables
CREATE INDEX IF NOT EXISTS IX_User_userName                    ON User(userName);
CREATE INDEX IF NOT EXISTS IX_UserCharacter_gameName           ON UserCharacter(gameName);
CREATE INDEX IF NOT EXISTS IX_UserCharacter_clanID             ON UserCharacter(clanID);
CREATE INDEX IF NOT EXISTS IX_UserInventory_userID             ON UserInventory(userID);
CREATE INDEX IF NOT EXISTS IX_UserInventory_expiry             ON UserInventory(expiryDate, inUse);
CREATE INDEX IF NOT EXISTS IX_UserLoadout_userID               ON UserLoadout(userID);
CREATE INDEX IF NOT EXISTS IX_UserBuyMenu_userID               ON UserBuyMenu(userID);
CREATE INDEX IF NOT EXISTS IX_UserFastBuy_userID               ON UserFastBuy(userID);
CREATE INDEX IF NOT EXISTS IX_UserBookmark_userID              ON UserBookmark(userID);
CREATE INDEX IF NOT EXISTS IX_UserCostumeLoadout_userID        ON UserCostumeLoadout(userID);
CREATE INDEX IF NOT EXISTS IX_UserZBCostumeLoadout_userID      ON UserZBCostumeLoadout(userID);
CREATE INDEX IF NOT EXISTS IX_UserAddon_userID                 ON UserAddon(userID);
CREATE INDEX IF NOT EXISTS IX_UserDailyReward_userID           ON UserDailyReward(userID);
CREATE INDEX IF NOT EXISTS IX_UserDailyRewardItems_userID      ON UserDailyRewardItems(userID);
CREATE INDEX IF NOT EXISTS IX_UserExpiryNotice_userID          ON UserExpiryNotice(userID);
CREATE INDEX IF NOT EXISTS IX_UserRewardNotice_userID          ON UserRewardNotice(userID);
CREATE INDEX IF NOT EXISTS IX_UserQuestProgress_userID         ON UserQuestProgress(userID);
CREATE INDEX IF NOT EXISTS IX_UserQuestTaskProgress_userID     ON UserQuestTaskProgress(userID);
CREATE INDEX IF NOT EXISTS IX_UserQuestEventProgress_userID    ON UserQuestEventProgress(userID);
CREATE INDEX IF NOT EXISTS IX_UserQuestEventTaskProgress_userID ON UserQuestEventTaskProgress(userID);
CREATE INDEX IF NOT EXISTS IX_UserMiniGameBingoSlot_userID     ON UserMiniGameBingoSlot(userID);
CREATE INDEX IF NOT EXISTS IX_UserMiniGameBingoPrizeSlot_userID ON UserMiniGameBingoPrizeSlot(userID);
CREATE INDEX IF NOT EXISTS IX_UserMiniGameWeaponReleaseCharacters_userID ON UserMiniGameWeaponReleaseCharacters(userID);
CREATE INDEX IF NOT EXISTS IX_UserMiniGameWeaponReleaseItemProgress_userID ON UserMiniGameWeaponReleaseItemProgress(userID);
CREATE INDEX IF NOT EXISTS IX_UserBanList_userID               ON UserBanList(userID);
CREATE INDEX IF NOT EXISTS IX_UserSessionHistory_userID        ON UserSessionHistory(userID);
CREATE INDEX IF NOT EXISTS IX_UserSurveyAnswer_userID          ON UserSurveyAnswer(userID);
CREATE INDEX IF NOT EXISTS IX_UserClassMod_userID              ON UserClassMod(userID);

-- ---------------------------------------------------------------- clan tables
CREATE INDEX IF NOT EXISTS IX_ClanMember_clanID                ON ClanMember(clanID);
CREATE INDEX IF NOT EXISTS IX_ClanStorageItem_clanID           ON ClanStorageItem(clanID);
CREATE INDEX IF NOT EXISTS IX_ClanStorageItem_expiry          ON ClanStorageItem(itemDuration);
CREATE INDEX IF NOT EXISTS IX_ClanStoragePage_clanID           ON ClanStoragePage(clanID);
CREATE INDEX IF NOT EXISTS IX_ClanChronicle_clanID             ON ClanChronicle(clanID);
CREATE INDEX IF NOT EXISTS IX_ClanInvite_clanID                ON ClanInvite(clanID);
CREATE INDEX IF NOT EXISTS IX_ClanMemberRequest_clanID         ON ClanMemberRequest(clanID);

-- -------------------------------------------------------------- anti-cheat/log
CREATE INDEX IF NOT EXISTS IX_SuspectAction_hwid               ON SuspectAction(hwid);

-- ------------------------------------------------------------- refresh + shrink
ANALYZE;
VACUUM;

-- Show the result
SELECT 'journal_mode: ' || (SELECT * FROM pragma_journal_mode);
SELECT 'page_count: '   || (SELECT * FROM pragma_page_count);
SELECT 'index count: '  || (SELECT count(*) FROM sqlite_master WHERE type='index' AND sql IS NOT NULL);
