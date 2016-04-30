/**
 * ==============================================================================
 * [TF2] Respawn System API!
 * Copyright (C) 2016 Benoist3012
 * ==============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */
#include <sourcemod>
#include <tf2_stocks>
#include <sdkhooks>
#include <tf2_respawn>

#define PLUGIN_VERSION "0.1"

#define TFTeam_Spectator 1
#define TFTeam_Red 2
#define TFTeam_Blue 3
#define TFTeam_Boss 5

public Plugin myinfo = 
{
	name			= "[TF2] Respawn System API!",
	author			= "Benoist3012",
	description		= "Custom API to override client's respawn time!",
	version			= PLUGIN_VERSION,
	url				= "http://steamcommunity.com/id/Benoist3012/"
};
//Gameplay entities.
int g_iPlayerManager;

//Client respawn time.
float g_flClientRespawnTime[MAXPLAYERS + 1];

//Respawn time logic.
float flRespawnTimeBlue;
float flRespawnTimeRed;
float flOldRespawnTimeBlue;
float flOldRespawnTimeRed;
float flOldRespawnWaveTimeRed = 0.0;
float flOldRespawnWaveTimeBlue = 0.0;

//Game's respawn convars.
Handle g_hCvarRespawnWaveTimes;

//Forwards
Handle fOnClientRespawnTimeSet;
Handle fOnTeamRespawnTimeChanged;
Handle fOnClientRespawnTimeUpdated;

/*
*
* General plugin hook functions
*
*/

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error,int err_max)
{
	RegPluginLibrary("tf2_respawn_time");
	
	fOnClientRespawnTimeSet = CreateGlobalForward("TF2_OnClientRespawnTimeSet", ET_Hook, Param_Cell, Param_FloatByRef);
	fOnTeamRespawnTimeChanged = CreateGlobalForward("TF2_OnTeamRespawnTimeChanged", ET_Hook, Param_Cell, Param_FloatByRef);
	fOnClientRespawnTimeUpdated = CreateGlobalForward("TF2_OnClientRespawnTimeUpdated", ET_Hook, Param_Cell, Param_FloatByRef);
	
	CreateNative("TF2_GetTeamRespawnTime", Native_GetTeamRespawnTime);
	CreateNative("TF2_GetClientRespawnTime", Native_GetClientRespawnTime);
	CreateNative("TF2_SetClientRespawnTime", Native_SetClientRespawnTime);
	CreateNative("TF2_UpdateClientRespawnTime", Native_UpdateClientRespawnTime);
	CreateNative("TF2_SetTeamRespawnTime", Native_SetTeamRespawnTime);
	CreateNative("TF2_UpdateTeamRespawnTime", Native_UpdateTeamRespawnTime);
	
	return APLRes_Success;
}
	
public void OnPluginStart()
{
	//Event Hooks.
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEvent("player_spawn", Event_PlayerSpawn);
	
	//Game's cvars.
	g_hCvarRespawnWaveTimes = FindConVar("mp_respawnwavetime");
	
	//Start the respawn time logic.
	CreateTimer(1.0, Timer_UpdateRespawnTimes, _, TIMER_REPEAT);
	
	CreateConVar("tf2_respawn_api", PLUGIN_VERSION, "[TF2] Respawn System API!", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
}

public void OnMapStart()
{
	//Find the tf_player_manager entity.
	g_iPlayerManager = GetPlayerResourceEntity();
}

/*
*
* Events
*
*/

public Action Event_PlayerSpawn(Handle hEvent, const char[] name, bool dontBroadcast)
{
	int iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	//Reset the desired respawn time.
	g_flClientRespawnTime[iClient] = 0.0;
	//Remove the hook.
	SDKUnhook(iClient, SDKHook_SetTransmit, OverrideRespawnHud);
}

public Action Event_PlayerDeath(Handle hEvent, const char[] name, bool dontBroadcast)
{
	int iClient = GetClientOfUserId(GetEventInt(hEvent, "userid"));
	if (GetEventInt(hEvent, "death_flags") & TF_DEATHFLAG_DEADRINGER) return;
	//Actually respawning a spectator will result in a crash.
	if(GetClientTeam(iClient) > 1 && !IsPlayerAlive(iClient))
	{
		//Set the client's respawn time.
		if(g_flClientRespawnTime[iClient] <= 0.0)
		{
			//Call our forward (TF2_OnClientRespawnTimeSet)
			Action iAction;
			float flRespawnTime = (GetClientTeam(iClient) == TFTeam_Blue) ? flRespawnTimeBlue : flRespawnTimeRed;
			float flRespawnTime2 = flRespawnTime;
			Call_StartForward(fOnClientRespawnTimeSet);
			Call_PushCell(iClient);
			Call_PushFloatRef(flRespawnTime2);
			Call_Finish(iAction);

			if (iAction == Plugin_Changed) flRespawnTime = flRespawnTime2;
			
			TF2_SetClientRespawnTimeEx(iClient, flRespawnTime);
		}
	}
}

/*
*
* Stocks
*
*/

public Action Timer_UpdateRespawnTimes(Handle hTimer)
{
	//Collect current team's respawn time.
	float flRespawnTime = GameRules_GetPropFloat("m_TeamRespawnWaveTimes", TFTeam_Blue);
	float flRespawnWaveTime = GetConVarFloat(g_hCvarRespawnWaveTimes);
	
	//The game updated the value, collect the new value, and set it back to 99999 secs.
	if(flRespawnTime < 99999.0)
	{	
		flRespawnTimeBlue = flRespawnTime;
		flOldRespawnWaveTimeBlue = 0.0;
		
		//Call our forward (TF2_OnTeamRespawnTimeChanged)
		Action iAction;
		float flRespawnTimeBlue2 = flRespawnTimeBlue;
		Call_StartForward(fOnTeamRespawnTimeChanged);
		Call_PushCell(TFTeam_Blue);
		Call_PushFloatRef(flRespawnTimeBlue2);
		Call_Finish(iAction);

		if (iAction == Plugin_Changed) flRespawnTimeBlue = flRespawnTimeBlue2;
		
		//Infinite value, set it to 9998.0, so the logic keeps going.
		if(flRespawnTimeBlue >= 99999.0) flRespawnTimeBlue = 9998.0;
		
		GameRules_SetPropFloat("m_TeamRespawnWaveTimes", 99999.0, TFTeam_Blue);
	}
	flRespawnTime = GameRules_GetPropFloat("m_TeamRespawnWaveTimes", TFTeam_Red);
	if(flRespawnTime < 99999.0)
	{
		flRespawnTimeRed = flRespawnTime;
		flOldRespawnWaveTimeRed = 0.0;
		
		//Call our forward (TF2_OnTeamRespawnTimeChanged)
		Action iAction;
		float flRespawnTimeRed2 = flRespawnTimeRed;
		Call_StartForward(fOnTeamRespawnTimeChanged);
		Call_PushCell(TFTeam_Red);
		Call_PushFloatRef(flRespawnTimeRed2);
		Call_Finish(iAction);

		if (iAction == Plugin_Changed) flRespawnTimeRed = flRespawnTimeRed2;
		
		//Infinite value, set it to 9998.0, so the logic keeps going.
		if(flRespawnTimeRed >= 99999.0) flRespawnTimeRed = 9998.0;
		
		GameRules_SetPropFloat("m_TeamRespawnWaveTimes", 99999.0, TFTeam_Red);
	}
	
	//Re-Calculate the respawn wave time for both team.
	float flRespawnWaveTimeRed = (flRespawnWaveTime-flOldRespawnWaveTimeRed);
	if(flRespawnWaveTimeRed != 0.0)
	{
		flRespawnTimeRed += flRespawnWaveTimeRed;
		flOldRespawnWaveTimeRed = GetConVarFloat(g_hCvarRespawnWaveTimes);
	}
	float flRespawnWaveTimeBlue = (flRespawnWaveTime-flOldRespawnWaveTimeBlue);
	if(flRespawnWaveTimeBlue != 0.0)
	{
		flRespawnTimeBlue += flRespawnWaveTimeBlue;
		flOldRespawnWaveTimeBlue = GetConVarFloat(g_hCvarRespawnWaveTimes);
	}
	
	//If the total respawn time is different from the old one, update the respawn time of every respawning clients of a team.
	float flNewRespawnTime = (flRespawnTimeBlue-flOldRespawnTimeBlue);
	if(flNewRespawnTime != 0.0)
		TF2_UpdateTeamRespawnEx(TFTeam_Blue, flNewRespawnTime);
	
	flNewRespawnTime = (flRespawnTimeRed-flOldRespawnTimeRed);
	if(flNewRespawnTime != 0.0)
		TF2_UpdateTeamRespawnEx(TFTeam_Red, flNewRespawnTime);
	
	flOldRespawnTimeBlue = flRespawnTimeBlue;
	flOldRespawnTimeRed = flRespawnTimeRed;
}

stock void TF2_SetClientRespawnTimeEx(int iClient,float flRespawnTime)
{
	//SetTransmit is faster than OnGameFrame to override the Respawn Hud, because the game tries to set it back.
	SDKHook(iClient, SDKHook_SetTransmit, OverrideRespawnHud);
	//Set our desired respawn time.
	g_flClientRespawnTime[iClient] = GetGameTime()+flRespawnTime;
}

stock void TF2_UpdateTeamRespawnEx(int iTeam,float flNewRespawnTime)
{
	for(int i=1; i<=MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == iTeam && g_flClientRespawnTime[i] > 0.0)
		{
			if(!IsPlayerAlive(i))
			{
				//Call our forward (TF2_OnClientRespawnTimeUpdated)
				Action iAction;
				float flNewRespawnTime2 = flNewRespawnTime;
				Call_StartForward(fOnClientRespawnTimeUpdated);
				Call_PushCell(i);
				Call_PushFloatRef(flNewRespawnTime2);
				Call_Finish(iAction);

				if (iAction == Plugin_Changed) flNewRespawnTime = flNewRespawnTime2;
				
				//Update client's respawn time.
				g_flClientRespawnTime[i] += flNewRespawnTime;
			}
		}
	}
}

stock void TF2_UpdateTeamRespawnEx2(int iTeam,float flNewRespawnTime)
{
	for(int i=1; i<=MaxClients; i++)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == iTeam && g_flClientRespawnTime[i] > 0.0)
		{
			if(!IsPlayerAlive(i))
			{
				//Update client's respawn time.
				g_flClientRespawnTime[i] += flNewRespawnTime;
			}
		}
	}
}

public Action OverrideRespawnHud(int iClient,int iOther)
{
	//Actually we are overriding the hud for one client only.
	if(iClient == iOther)
	{
		//Set the desired respawn time on the Hud.
		SetEntPropFloat(g_iPlayerManager, Prop_Send, "m_flNextRespawnTime", g_flClientRespawnTime[iClient], iClient);
		//Make the client respawn if our desired respawn time is elapsed.
		if(g_flClientRespawnTime[iClient] < GetGameTime())
		{
			//Respawn the player.
			TF2_RespawnPlayer(iClient);
			//Reset the desired respawn time.
			g_flClientRespawnTime[iClient] = 0.0;
			//Remove the hook.
			SDKUnhook(iClient, SDKHook_SetTransmit, OverrideRespawnHud);
		}
	}
}

/*
*
* Natives
*
*/

public int Native_GetTeamRespawnTime(Handle hPlugin,int iNumParams)
{
	int iTeam = GetNativeCell(1);
	float flRespawnTime = 0.0;
	if(1 < iTeam < 4)
		flRespawnTime = GameRules_GetPropFloat("m_TeamRespawnWaveTimes", iTeam);
	return view_as<int>(flRespawnTime);
}

public int Native_GetClientRespawnTime(Handle hPlugin,int iNumParams)
{
	int iClient = GetNativeCell(1);
	return view_as<int>(g_flClientRespawnTime[iClient]);
}

public int Native_SetClientRespawnTime(Handle hPlugin,int iNumParams)
{
	int iClient = GetNativeCell(1);
	float flRespawnTime = view_as<float>(GetNativeCell(2));
	if(IsClientInGame(iClient) && !IsPlayerAlive(iClient))
	{
		if(g_flClientRespawnTime[iClient] <= 0.0)
		{
			TF2_SetClientRespawnTimeEx(iClient, flRespawnTime);
			return view_as<bool>(true);
		}
	}
	return view_as<bool>(false);
}

public int Native_UpdateClientRespawnTime(Handle hPlugin,int iNumParams)
{
	int iClient = GetNativeCell(1);
	float flNewRespawnTime = view_as<float>(GetNativeCell(2));
	if(IsClientInGame(iClient) && !IsPlayerAlive(iClient))
	{
		g_flClientRespawnTime[iClient] += flNewRespawnTime;
		return view_as<bool>(true);
	}
	return view_as<bool>(false);
}

public int Native_SetTeamRespawnTime(Handle hPlugin,int iNumParams)
{
	int iTeam = GetNativeCell(1);
	float flRespawnTime = view_as<float>(GetNativeCell(2));
	if(1 < iTeam < 4)
	{
		GameRules_SetPropFloat("m_TeamRespawnWaveTimes", flRespawnTime, iTeam);
		return view_as<bool>(true);
	}
	return view_as<bool>(false);
}

public int Native_UpdateTeamRespawnTime(Handle hPlugin,int iNumParams)
{
	int iTeam = GetNativeCell(1);
	float flNewRespawnTime = view_as<float>(GetNativeCell(2));
	if(1 < iTeam < 4)
	{
		TF2_UpdateTeamRespawnEx2(iTeam, flNewRespawnTime);
		return view_as<bool>(true);
	}
	return view_as<bool>(false);
}