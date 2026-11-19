/**
 * SourceCoop Ready-up
 *
 * Holds the start of a session until everyone is ready:
 *  - On the first map after a server start (and after an idle reload), the
 *    map stays in SourceCoop's intro hold until every player in game has
 *    typed !ready and nobody is still loading in. !forcestart starts a vote
 *    (admins start immediately), and an optional time limit starts it anyway.
 *  - Map changes during play are not affected (SourceCoop's normal start).
 *  - When the server has been empty for a while, the current map is reloaded
 *    so the next session gets the ready-up wait again.
 *
 * SourceCoop has no API to hold or release its start timer. The countdown is
 * only (re)evaluated when a player spawns, so this plugin:
 *  - sets sourcecoop_start_wait_mode 0 and a long sourcecoop_start_wait_period
 *    while holding (SourceCoop then waits up to that long);
 *  - on release, sets mode 2 and respawns one player. On the first map after
 *    a boot, mode 2 always skips to SourceCoop's 3-second countdown.
 * Maps without an intro start immediately in SourceCoop; there this plugin
 * freezes players itself until release.
 */
#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define TAG           "\x04[Ready]\x01"
#define SAVE_DIR      "data/srccoop/savedata"
#define GEAR_FILE     "readyup_tmp.txt"
#define VOTE_COOLDOWN 30
#define DAMAGE_NO     0
#define DAMAGE_YES    2

public Plugin myinfo =
{
	name = "SourceCoop Ready-up",
	author = "blackmesa-coop",
	description = "Waits for everyone to type !ready before a session starts",
	version = "1.0.0",
	url = "https://github.com/BryanBest/blackmesa-coop"
};

ConVar g_cvEnabled;
ConVar g_cvTimeout;
ConVar g_cvIdleReload;
ConVar g_cvScMode;
ConVar g_cvScPeriod;

bool g_bHoldNextMap = true;   // first map after load, or after an idle reload
bool g_bHolding;              // waiting for players on this map
bool g_bReleasing;            // released; waiting for SourceCoop to start
bool g_bCoopStarted;          // SC_OnCoopMapStart fired on this map
bool g_bReady[MAXPLAYERS + 1];
bool g_bFrozen[MAXPLAYERS + 1];
int g_iTimeLeft;
int g_iTicks;
int g_iLastVote;
int g_iGearUserId;            // player whose gear is restored after the release respawn

bool g_bSavedCvars;
char g_szSavedMode[16];
char g_szSavedPeriod[16];

Handle g_hIdleTimer;
Handle g_hHudSync;

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("sc_readyup_enabled", "1", "Wait for everyone to type !ready before a session starts.", _, true, 0.0, true, 1.0);
	g_cvTimeout = CreateConVar("sc_readyup_timeout", "600", "Seconds to wait (after the first player is in) before starting anyway. 0 = wait until everyone is ready.", _, true, 0.0);
	g_cvIdleReload = CreateConVar("sc_readyup_idle_reload", "600", "Reload the current map after the server has been empty this many seconds, so the next session waits for ready-up. 0 = off.", _, true, 0.0);

	RegConsoleCmd("sm_ready", Command_Ready, "Mark yourself as ready.");
	RegConsoleCmd("sm_r", Command_Ready, "Mark yourself as ready.");
	RegConsoleCmd("sm_unready", Command_Unready, "Mark yourself as not ready.");
	RegConsoleCmd("sm_forcestart", Command_ForceStart, "Start without waiting for everyone (vote; admins start immediately).");

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

	g_hHudSync = CreateHudSynchronizer();

	// Loaded while people are already playing: don't hold the current map.
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			g_bHoldNextMap = false;
			break;
		}
	}
}

public void OnPluginEnd()
{
	RestoreCvars();
}

// --------------------------------------------------------------------------
// Map lifecycle
// --------------------------------------------------------------------------

public void OnMapStart()
{
	g_bCoopStarted = false;
	g_bReleasing = false;
	g_iGearUserId = 0;
	g_iLastVote = 0;
	g_hIdleTimer = null; // TIMER_FLAG_NO_MAPCHANGE timers are gone
	for (int i = 0; i <= MaxClients; i++)
	{
		g_bReady[i] = false;
		g_bFrozen[i] = false;
	}

	g_bHolding = g_bHoldNextMap && g_cvEnabled.BoolValue;
	g_bHoldNextMap = false;

	if (g_bHolding)
	{
		g_iTimeLeft = g_cvTimeout.IntValue;
		g_iTicks = 0;
		CreateTimer(1.0, Timer_Tick, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnConfigsExecuted()
{
	if (!g_bHolding)
		return;

	g_cvScMode = FindConVar("sourcecoop_start_wait_mode");
	g_cvScPeriod = FindConVar("sourcecoop_start_wait_period");
	if (g_cvScMode == null || g_cvScPeriod == null)
	{
		LogError("SourceCoop cvars not found; ready-up disabled for this map.");
		g_bHolding = false;
		return;
	}

	if (!g_bSavedCvars)
	{
		g_cvScMode.GetString(g_szSavedMode, sizeof(g_szSavedMode));
		g_cvScPeriod.GetString(g_szSavedPeriod, sizeof(g_szSavedPeriod));
		g_bSavedCvars = true;
	}

	int timeout = g_cvTimeout.IntValue;
	// SourceCoop's own timer is only a backstop; this plugin releases first.
	g_cvScMode.IntValue = 0;
	g_cvScPeriod.IntValue = timeout > 0 ? timeout + 30 : 86400;

	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	LogMessage("Holding the start of %s until everyone is ready.", map);
}

public void OnMapEnd()
{
	g_bHolding = false;
	g_bReleasing = false;
	RestoreCvars();
}

void RestoreCvars()
{
	if (!g_bSavedCvars)
		return;
	if (g_cvScMode != null)
		g_cvScMode.SetString(g_szSavedMode);
	if (g_cvScPeriod != null)
		g_cvScPeriod.SetString(g_szSavedPeriod);
	g_bSavedCvars = false;
}

// Forward from SourceCoop: the map has started (intro over).
public void SC_OnCoopMapStart()
{
	g_bCoopStarted = true;

	if (g_bReleasing)
	{
		g_bReleasing = false;
		RestoreCvars();
	}
	else if (g_bHolding)
	{
		// A map without an intro (or SourceCoop's backstop): hold players ourselves.
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && IsPlayerAlive(i))
				Freeze(i);
		}
	}
}

// --------------------------------------------------------------------------
// Clients
// --------------------------------------------------------------------------

public void OnClientConnected(int client)
{
	g_bReady[client] = false;
	g_bFrozen[client] = false;
	if (!IsFakeClient(client))
	{
		delete g_hIdleTimer;
	}
}

public void OnClientDisconnect(int client)
{
	g_bReady[client] = false;
	g_bFrozen[client] = false;
}

public void OnClientDisconnect_Post(int client)
{
	if (g_bHolding || g_hIdleTimer != null || !g_cvEnabled.BoolValue)
		return;
	float delay = g_cvIdleReload.FloatValue;
	if (delay <= 0.0 || HumansConnected() > 0)
		return;
	g_hIdleTimer = CreateTimer(delay, Timer_IdleReload, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_IdleReload(Handle timer)
{
	g_hIdleTimer = null;
	if (HumansConnected() > 0 || !g_cvEnabled.BoolValue)
		return Plugin_Stop;

	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	LogMessage("Server has been empty; reloading %s so the next session waits for ready-up.", map);
	g_bHoldNextMap = true;
	ForceChangeLevel(map, "Ready-up idle reload");
	return Plugin_Stop;
}

int HumansConnected()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
			n++;
	}
	return n;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if (!client || IsFakeClient(client))
		return;

	if (g_bHolding && g_bCoopStarted)
	{
		RequestFrame(Frame_Freeze, userid);
	}
	if (g_iGearUserId != 0 && userid == g_iGearUserId)
	{
		CreateTimer(0.5, Timer_RestoreGear, userid, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void Frame_Freeze(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client && g_bHolding && IsClientInGame(client) && IsPlayerAlive(client))
		Freeze(client);
}

void Freeze(int client)
{
	SetEntityFlags(client, GetEntityFlags(client) | FL_FROZEN | FL_ATCONTROLS | FL_NOTARGET);
	SetEntProp(client, Prop_Data, "m_takedamage", DAMAGE_NO);
	g_bFrozen[client] = true;
}

void Unfreeze(int client)
{
	SetEntityFlags(client, GetEntityFlags(client) & ~(FL_FROZEN | FL_ATCONTROLS | FL_NOTARGET));
	SetEntProp(client, Prop_Data, "m_takedamage", DAMAGE_YES);
	g_bFrozen[client] = false;
}

// --------------------------------------------------------------------------
// Waiting loop
// --------------------------------------------------------------------------

void Count(int &inGame, int &ready, int &loading)
{
	inGame = 0; ready = 0; loading = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || IsFakeClient(i))
			continue;
		if (!IsClientInGame(i))
		{
			loading++;
			continue;
		}
		inGame++;
		if (g_bReady[i])
			ready++;
	}
}

public Action Timer_Tick(Handle timer)
{
	if (!g_bHolding)
		return Plugin_Stop;

	int inGame, ready, loading;
	Count(inGame, ready, loading);

	if (inGame == 0)
	{
		// Nobody here yet: the time limit starts when the first player is in.
		g_iTimeLeft = g_cvTimeout.IntValue;
		g_iTicks = 0;
		return Plugin_Continue;
	}

	if (ready == inGame && loading == 0)
	{
		Release("Everyone is ready");
		return Plugin_Stop;
	}

	int timeout = g_cvTimeout.IntValue;
	if (timeout > 0 && --g_iTimeLeft <= 0)
	{
		Release("Time limit reached");
		return Plugin_Stop;
	}

	ShowStatus(inGame, ready, loading, timeout > 0);

	if (++g_iTicks % 30 == 1)
		AnnounceWaiting();

	return Plugin_Continue;
}

void ShowStatus(int inGame, int ready, int loading, bool timed)
{
	if (g_hHudSync == null)
		return;

	char extra[64], timeText[64], hint[96];
	if (loading > 0)
		FormatEx(extra, sizeof(extra), " (%d still loading)", loading);
	if (timed)
		FormatEx(timeText, sizeof(timeText), "\nStarting anyway in %d:%02d", g_iTimeLeft / 60, g_iTimeLeft % 60);

	SetHudTextParams(-1.0, 0.12, 1.1, 255, 200, 40, 255, 0, 0.0, 0.0, 0.0);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;
		if (g_bReady[i])
			strcopy(hint, sizeof(hint), "You are ready. !unready to undo, !forcestart to vote");
		else
			strcopy(hint, sizeof(hint), "Type !ready in chat when you're set");
		ShowSyncHudText(i, g_hHudSync, "Waiting for players: %d/%d ready%s\n%s%s",
			ready, inGame, extra, hint, timeText);
	}
}

void AnnounceWaiting()
{
	char names[256];
	char name[MAX_NAME_LENGTH + 12];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || IsFakeClient(i))
			continue;
		bool inGame = IsClientInGame(i);
		if (inGame && g_bReady[i])
			continue;
		if (inGame)
			FormatEx(name, sizeof(name), "%N", i);
		else
			FormatEx(name, sizeof(name), "%N (loading)", i);
		if (names[0] != '\0')
			StrCat(names, sizeof(names), ", ");
		StrCat(names, sizeof(names), name);
	}
	if (names[0] != '\0')
		PrintToChatAll("%s Waiting on: %s. Type \x04!ready\x01 when you're set.", TAG, names);
}

// --------------------------------------------------------------------------
// Release
// --------------------------------------------------------------------------

void Release(const char[] reason)
{
	if (!g_bHolding)
		return;
	g_bHolding = false;

	PrintToChatAll("%s %s. Starting!", TAG, reason);
	LogMessage("Releasing the start: %s", reason);

	if (g_bCoopStarted)
	{
		// SourceCoop already started (map without an intro): just unfreeze.
		for (int i = 1; i <= MaxClients; i++)
		{
			if (g_bFrozen[i] && IsClientInGame(i))
				Unfreeze(i);
		}
		RestoreCvars();
		return;
	}

	// Mode 2 on the first map after a boot always jumps to SourceCoop's
	// 3-second countdown on the next spawn. Restored once the map starts.
	g_bReleasing = true;
	if (g_cvScMode != null)
		g_cvScMode.IntValue = 2;
	if (g_cvScPeriod != null && g_bSavedCvars)
		g_cvScPeriod.SetString(g_szSavedPeriod);

	int client = PickPlayer();
	if (!client)
		return; // the next spawn starts the countdown

	int userid = GetClientUserId(client);
	SaveGear();
	g_iGearUserId = userid;

	// Re-runs SourceCoop's spawn handling, which starts the countdown.
	DispatchSpawn(client);
	CreateTimer(0.5, Timer_RestoreGear, userid, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(8.0, Timer_CheckStarted, userid, TIMER_FLAG_NO_MAPCHANGE);
}

int PickPlayer()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && IsPlayerAlive(i))
			return i;
	}
	return 0;
}

void GearPath(char[] path, int maxlen)
{
	BuildPath(Path_SM, path, maxlen, "%s/%s", SAVE_DIR, GEAR_FILE);
}

void SaveGear()
{
	char path[PLATFORM_MAX_PATH];
	GearPath(path, sizeof(path));
	DeleteFile(path);
	ServerCommand("sc_save %s", GEAR_FILE);
	ServerExecute();
}

public Action Timer_RestoreGear(Handle timer, int userid)
{
	if (userid != g_iGearUserId)
		return Plugin_Stop;

	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client) || !IsPlayerAlive(client))
		return Plugin_Stop; // dead: retried from the next player_spawn

	g_iGearUserId = 0;
	char path[PLATFORM_MAX_PATH];
	GearPath(path, sizeof(path));
	if (FileExists(path))
	{
		ServerCommand("sc_load %s #%d", GEAR_FILE, userid);
		ServerExecute();
		DeleteFile(path);
	}
	return Plugin_Stop;
}

// Fallback if the in-place respawn did not start SourceCoop's countdown:
// kill the player; mp_forcerespawn respawns them and the spawn starts it.
public Action Timer_CheckStarted(Handle timer, int userid)
{
	if (g_bCoopStarted || !g_bReleasing)
		return Plugin_Stop;

	int client = GetClientOfUserId(userid);
	if (!client || !IsClientInGame(client))
		client = PickPlayer();
	if (!client)
		return Plugin_Stop;

	LogMessage("Countdown did not start after the respawn; using the respawn fallback.");
	userid = GetClientUserId(client);
	SaveGear();
	g_iGearUserId = userid;
	ForcePlayerSuicide(client);
	return Plugin_Stop;
}

// --------------------------------------------------------------------------
// Commands
// --------------------------------------------------------------------------

public Action Command_Ready(int client, int args)
{
	if (!client)
		return Plugin_Handled;
	if (!g_bHolding)
	{
		ReplyToCommand(client, "%s The game has already started.", TAG);
		return Plugin_Handled;
	}
	if (!g_bReady[client])
	{
		g_bReady[client] = true;
		int inGame, ready, loading;
		Count(inGame, ready, loading);
		PrintToChatAll("%s %N is ready (%d/%d).", TAG, client, ready, inGame);
	}
	return Plugin_Handled;
}

public Action Command_Unready(int client, int args)
{
	if (!client || !g_bHolding)
		return Plugin_Handled;
	if (g_bReady[client])
	{
		g_bReady[client] = false;
		PrintToChatAll("%s %N is no longer ready.", TAG, client);
	}
	return Plugin_Handled;
}

public Action Command_ForceStart(int client, int args)
{
	if (!g_bHolding)
	{
		ReplyToCommand(client, "%s The game has already started.", TAG);
		return Plugin_Handled;
	}

	// Server console and admins start immediately.
	if (!client || CheckCommandAccess(client, "sm_forcestart_admin", ADMFLAG_CHANGEMAP, true))
	{
		if (client)
			PrintToChatAll("%s %N forced the start.", TAG, client);
		Release("Start forced");
		return Plugin_Handled;
	}

	if (IsVoteInProgress())
	{
		ReplyToCommand(client, "%s A vote is already in progress.", TAG);
		return Plugin_Handled;
	}
	int wait = g_iLastVote + VOTE_COOLDOWN - GetTime();
	if (wait > 0)
	{
		ReplyToCommand(client, "%s Wait %d seconds before starting another vote.", TAG, wait);
		return Plugin_Handled;
	}
	g_iLastVote = GetTime();

	Menu menu = new Menu(Handler_Vote);
	menu.SetTitle("Start now without waiting for everyone?");
	menu.AddItem("yes", "Yes, start now");
	menu.AddItem("no", "No, keep waiting");
	menu.ExitButton = false;
	menu.VoteResultCallback = VoteResult;
	menu.DisplayVoteToAll(20);
	PrintToChatAll("%s %N started a vote to start now.", TAG, client);
	return Plugin_Handled;
}

public int Handler_Vote(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_VoteCancel)
	{
		PrintToChatAll("%s Vote failed (no votes).", TAG);
	}
	return 0;
}

public void VoteResult(Menu menu, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	int yes = 0;
	for (int i = 0; i < num_items; i++)
	{
		char info[8];
		menu.GetItem(item_info[i][VOTEINFO_ITEM_INDEX], info, sizeof(info));
		if (StrEqual(info, "yes"))
			yes = item_info[i][VOTEINFO_ITEM_VOTES];
	}

	if (num_votes > 0 && yes * 2 > num_votes)
	{
		Release("Vote passed");
	}
	else
	{
		PrintToChatAll("%s Vote failed (%d of %d voted yes).", TAG, yes, num_votes);
	}
}
