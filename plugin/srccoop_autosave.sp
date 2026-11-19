/**
 * SourceCoop Autosave
 *
 * Lightweight "continue where we left off" for SourceCoop servers:
 *  - Records the current map to data/srccoop/savedata/autosave_map.txt
 *    (the container's start script resumes on that map after a restart).
 *  - Periodically, and when a player leaves, runs SourceCoop's `sc_save` and
 *    keeps one file per player (players/<accountid>.txt) so players who left
 *    earlier keep their gear. These are combined into autosave.txt, which is
 *    the format SourceCoop's `sc_load` reads.
 *  - On the first map after a server start (or a map loaded while the server
 *    was empty), restores each returning player's gear once with
 *    `sc_load autosave.txt #<userid>`.
 *
 * Mid-map position is not saved; players restart at the map's spawn.
 */
#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define SAVE_DIR      "data/srccoop/savedata"
#define TMP_FILE      "autosave_tmp.txt"
#define COMBINED_FILE "autosave.txt"
#define MAP_FILE      "autosave_map.txt"
#define PLAYERS_DIR   "players"

public Plugin myinfo =
{
	name = "SourceCoop Autosave",
	author = "blackmesa-coop",
	description = "Saves the current map and player equipment, and restores them after a restart",
	version = "1.0.0",
	url = "https://github.com/BryanBest/blackmesa-coop"
};

ConVar g_cvEnabled;
ConVar g_cvInterval;

int g_iMapStarts;            // number of maps started since the plugin loaded
bool g_bRestoreWindow;       // this map started on a fresh/empty server
bool g_bHumansAtMapEnd;      // someone was connected when the last map ended
float g_fSinceSave;          // seconds since the last periodic save
StringMap g_smPending;       // account ids waiting for their restore (this boot)
StringMap g_smRestored;      // account ids already restored (this boot)

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("sc_autosave_enabled", "1", "Enable automatic saving/restoring of map and player equipment.", _, true, 0.0, true, 1.0);
	g_cvInterval = CreateConVar("sc_autosave_interval", "120", "Seconds between automatic equipment saves.", _, true, 15.0);

	RegAdminCmd("sc_autosave_now", Command_SaveNow, ADMFLAG_ROOT, "Save player equipment now.");
	RegAdminCmd("sc_autosave_reset", Command_Reset, ADMFLAG_ROOT, "Delete all autosave data (start the campaign over).");

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

	g_smPending = new StringMap();
	g_smRestored = new StringMap();

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "%s/%s", SAVE_DIR, PLAYERS_DIR);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}

	CreateTimer(10.0, Timer_Tick, _, TIMER_REPEAT);
}

// --------------------------------------------------------------------------
// Map tracking
// --------------------------------------------------------------------------

public void OnMapStart()
{
	g_iMapStarts++;
	g_fSinceSave = 0.0;

	// Restore on the first map after a server start, and on a map loaded
	// while nobody was connected (e.g. the ready-up idle reload). Normal map
	// changes keep players connected, and SourceCoop carries their gear.
	g_bRestoreWindow = g_iMapStarts <= 1 || !g_bHumansAtMapEnd;
	if (g_bRestoreWindow && g_iMapStarts > 1)
	{
		g_smRestored.Clear();
	}

	if (!g_cvEnabled.BoolValue)
		return;

	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "%s/%s", SAVE_DIR, MAP_FILE);
	File f = OpenFile(path, "w");
	if (f != null)
	{
		f.WriteLine("%s", map);
		delete f;
	}
	else
	{
		LogError("Could not write %s", path);
	}
}

public void OnMapEnd()
{
	g_bHumansAtMapEnd = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
		{
			g_bHumansAtMapEnd = true;
			break;
		}
	}
}

bool InRestoreWindow()
{
	return g_bRestoreWindow;
}

// --------------------------------------------------------------------------
// Saving
// --------------------------------------------------------------------------

public Action Timer_Tick(Handle timer)
{
	g_fSinceSave += 10.0;
	if (g_fSinceSave >= g_cvInterval.FloatValue)
	{
		g_fSinceSave = 0.0;
		SaveAll();
	}
	return Plugin_Continue;
}

public void OnClientDisconnect(int client)
{
	if (!IsFakeClient(client) && IsClientInGame(client))
	{
		SaveAll();
	}
}

bool HasHumans()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			return true;
	}
	return false;
}

void SaveAll()
{
	if (!g_cvEnabled.BoolValue || !HasHumans())
		return;

	char tmpPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, tmpPath, sizeof(tmpPath), "%s/%s", SAVE_DIR, TMP_FILE);
	DeleteFile(tmpPath);

	// SourceCoop writes every online player's equipment to the tmp file.
	ServerCommand("sc_save %s", TMP_FILE);
	ServerExecute();

	if (!FileExists(tmpPath))
		return; // nobody alive / nothing to save

	KeyValues kv = new KeyValues("SaveData");
	if (!kv.ImportFromFile(tmpPath))
	{
		LogError("Could not parse %s", tmpPath);
		delete kv;
		return;
	}

	int saved = 0;
	if (kv.GotoFirstSubKey(true))
	{
		do
		{
			char sid[32];
			kv.GetSectionName(sid, sizeof(sid));

			// Don't overwrite a returning player's save with their fresh
			// spawn gear before it has been restored.
			int dummy;
			if (g_smPending.GetValue(sid, dummy))
				continue;

			char playerPath[PLATFORM_MAX_PATH];
			BuildPath(Path_SM, playerPath, sizeof(playerPath), "%s/%s/%s.txt", SAVE_DIR, PLAYERS_DIR, sid);
			// Exports from the current position: writes this player's section.
			if (kv.ExportToFile(playerPath))
				saved++;
		}
		while (kv.GotoNextKey(true));
	}
	delete kv;
	DeleteFile(tmpPath);

	if (saved > 0)
	{
		RebuildCombined();
	}
}

// Concatenates players/*.txt into autosave.txt: "SaveData" { <sections> }
void RebuildCombined()
{
	char dirPath[PLATFORM_MAX_PATH], outPath[PLATFORM_MAX_PATH], newPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dirPath, sizeof(dirPath), "%s/%s", SAVE_DIR, PLAYERS_DIR);
	BuildPath(Path_SM, outPath, sizeof(outPath), "%s/%s", SAVE_DIR, COMBINED_FILE);
	FormatEx(newPath, sizeof(newPath), "%s.new", outPath);

	DirectoryListing dir = OpenDirectory(dirPath);
	if (dir == null)
		return;

	File out = OpenFile(newPath, "w");
	if (out == null)
	{
		delete dir;
		LogError("Could not write %s", newPath);
		return;
	}

	out.WriteLine("\"SaveData\"");
	out.WriteLine("{");

	char name[PLATFORM_MAX_PATH], filePath[PLATFORM_MAX_PATH], line[1024];
	FileType type;
	while (dir.GetNext(name, sizeof(name), type))
	{
		if (type != FileType_File || StrContains(name, ".txt") == -1)
			continue;

		FormatEx(filePath, sizeof(filePath), "%s/%s", dirPath, name);
		File fin = OpenFile(filePath, "r");
		if (fin == null)
			continue;
		while (fin.ReadLine(line, sizeof(line)))
		{
			out.WriteString(line, false);
		}
		delete fin;
		out.WriteLine("");
	}
	out.WriteLine("}");
	delete out;
	delete dir;

	DeleteFile(outPath);
	RenameFile(outPath, newPath);
}

// --------------------------------------------------------------------------
// Restoring (first map after a server start only)
// --------------------------------------------------------------------------

bool GetAccountKey(int client, char[] key, int maxlen)
{
	int sid = GetSteamAccountID(client, false);
	if (!sid)
		return false;
	IntToString(sid, key, maxlen);
	return true;
}

bool HasSave(const char[] sid)
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "%s/%s/%s.txt", SAVE_DIR, PLAYERS_DIR, sid);
	return FileExists(path);
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client) || !g_cvEnabled.BoolValue || !InRestoreWindow())
		return;

	char sid[32];
	int dummy;
	if (GetAccountKey(client, sid, sizeof(sid)) && HasSave(sid) && !g_smRestored.GetValue(sid, dummy))
	{
		g_smPending.SetValue(sid, 1);
	}
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (!client || IsFakeClient(client) || !g_cvEnabled.BoolValue || !InRestoreWindow())
		return;

	char sid[32];
	int dummy;
	if (GetAccountKey(client, sid, sizeof(sid)) && g_smPending.GetValue(sid, dummy))
	{
		// Let SourceCoop finish giving spawn equipment first.
		CreateTimer(1.5, Timer_Restore, userid, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_Restore(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client) || !IsPlayerAlive(client))
		return Plugin_Stop;

	char sid[32];
	int dummy;
	if (!GetAccountKey(client, sid, sizeof(sid)) || !g_smPending.GetValue(sid, dummy))
		return Plugin_Stop;

	ServerCommand("sc_load %s #%d", COMBINED_FILE, userid);
	ServerExecute();

	g_smPending.Remove(sid);
	g_smRestored.SetValue(sid, 1);
	PrintToChat(client, "[Autosave] Restored your gear from the last session.");
	return Plugin_Stop;
}

// --------------------------------------------------------------------------
// Commands
// --------------------------------------------------------------------------

public Action Command_SaveNow(int client, int args)
{
	SaveAll();
	ReplyToCommand(client, "[Autosave] Saved.");
	return Plugin_Handled;
}

public Action Command_Reset(int client, int args)
{
	char path[PLATFORM_MAX_PATH], dirPath[PLATFORM_MAX_PATH], name[PLATFORM_MAX_PATH];

	BuildPath(Path_SM, path, sizeof(path), "%s/%s", SAVE_DIR, MAP_FILE);
	DeleteFile(path);
	BuildPath(Path_SM, path, sizeof(path), "%s/%s", SAVE_DIR, COMBINED_FILE);
	DeleteFile(path);

	BuildPath(Path_SM, dirPath, sizeof(dirPath), "%s/%s", SAVE_DIR, PLAYERS_DIR);
	DirectoryListing dir = OpenDirectory(dirPath);
	if (dir != null)
	{
		FileType type;
		while (dir.GetNext(name, sizeof(name), type))
		{
			if (type == FileType_File)
			{
				FormatEx(path, sizeof(path), "%s/%s", dirPath, name);
				DeleteFile(path);
			}
		}
		delete dir;
	}

	g_smPending.Clear();
	ReplyToCommand(client, "[Autosave] All saved progress deleted. Run 'changelevel bm_c0a0a' to start the campaign over.");
	return Plugin_Handled;
}
