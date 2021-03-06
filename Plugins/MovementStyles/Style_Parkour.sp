#include <sourcemod>
#include <sdkhooks>
#include <sdktools_functions>
#include <sdktools_engine>
#include <sdktools_trace>
#include <sdktools_tempents>
#include <sdktools_tempents_stocks>
#include <sdktools_entinput>
#include "../../Libraries/MovementStyles/movement_styles"

#pragma semicolon 1

new const String:PLUGIN_NAME[] = "Style: Parkour";
new const String:PLUGIN_VERSION[] = "1.0";

public Plugin:myinfo =
{
	name = PLUGIN_NAME,
	author = "Hymns For Disco",
	description = "Style: Parkour.",
	version = PLUGIN_VERSION,
	url = "www.swoobles.com"
}

#define THIS_STYLE_BIT			STYLE_BIT_PARKOUR
#define THIS_STYLE_NAME			"Parkour"
#define THIS_STYLE_NAME_AUTO	"Parkour + Auto Bhop"
#define THIS_STYLE_ORDER		120

new Handle:cvar_add_autobhop;
new Handle:cvar_force_autobhop;


new const FSOLID_NOT_SOLID = 0x0004;
new const FSOLID_TRIGGER = 0x0008;
#define SOLID_NONE	0
#define COLLISION_GROUP_PLAYER_MOVEMENT	8
#define ROCKET_COLLISION_GROUP	COLLISION_GROUP_PLAYER_MOVEMENT

#define USE_SPECIFIED_BOUNDS	3

new const Float:g_fRocketMins[3] = {-0.0, -0.0, -0.0};
new const Float:g_fRocketMaxs[3] = {0.0, 0.0, 0.0};

#define WALLJUMP_COOLDOWN_BASE 1.0
#define WALLJUMP_MAX_IN_AIR 3
#define TRACE_HULL_RADIUS 40.0
#define WALLJUMP_VERTICAL_VELOCITY 200.0

#define GRAPPLE_PULL_MAX 400.0
#define GRAPPLE_PULL_ACCEL 25.0
#define GRAPPLE_CHARGE_MAX 1024.0
#define GRAPPLE_CHARGE_USE -3.5
#define GRAPPLE_CHARGE_REGEN 1.0
#define GRAPPLE_CHARGE_WALLJUMP 200.0
#define GRAPPLE_HOOK_SPEED 4500.0

enum _:ParkourData
{
	Parkour_Ticks,
	bool:Parkour_Enabled,
	Grapple_HookEntityRef,
	Float:Grapple_Charge,
	bool:Grapple_Hooked,
	bool:Grapple_Expired,
	Float:WallJump_LastJumpTime,
	WallJump_JumpsSinceGround
};

new g_eParkourData[MAXPLAYERS + 1][ParkourData];

new g_Sprite;


public OnPluginStart()
{
	CreateConVar("style_parkour_ver", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_PRINTABLEONLY);
	
	cvar_add_autobhop = CreateConVar("style_parkour_add_autobhop", "0", "Add an additional auto-bhop style for this style too.", _, true, 0.0, true, 1.0);
	cvar_force_autobhop = CreateConVar("style_parkour_force_autobhop", "0", "Force auto-bhop on this style.", _, true, 0.0, true, 1.0);
}

public OnMapStart()
{
	g_Sprite = PrecacheModel("materials/sprites/laserbeam.vmt");
}

public MovementStyles_OnRegisterReady()
{
	MovementStyles_RegisterStyle(THIS_STYLE_BIT, THIS_STYLE_NAME, OnActivated, OnDeactivated, THIS_STYLE_ORDER, GetConVarBool(cvar_force_autobhop) ? THIS_STYLE_NAME_AUTO : "");
}

public MovementStyles_OnRegisterMultiReady()
{
	if(GetConVarBool(cvar_add_autobhop) && !GetConVarBool(cvar_force_autobhop))
		MovementStyles_RegisterMultiStyle(THIS_STYLE_BIT | STYLE_BIT_AUTO_BHOP, THIS_STYLE_NAME_AUTO, THIS_STYLE_ORDER + 1);
}

public MovementStyles_OnBitsChanged(iClient, iOldBits, &iNewBits)
{
	// Do not compare using bitwise operators. The bit should be an exact equal.
	if(iNewBits != THIS_STYLE_BIT)
		return;
	
	iNewBits = TryForceAutoBhopBits(iNewBits);
}

public Action:MovementStyles_OnMenuBitsChanged(iClient, iBitsBeingToggled, bool:bBeingToggledOn, &iExtraBitsToForceOn)
{
	// Do not compare using bitwise operators. The bit should be an exact equal.
	if(!bBeingToggledOn || iBitsBeingToggled != THIS_STYLE_BIT)
		return;
	
	iExtraBitsToForceOn = TryForceAutoBhopBits(iExtraBitsToForceOn);
}

TryForceAutoBhopBits(iBits)
{
	if(!GetConVarBool(cvar_force_autobhop))
		return iBits;
	
	return (iBits | STYLE_BIT_AUTO_BHOP);
}

public OnClientConnected(iClient)
{
	g_eParkourData[iClient][Parkour_Enabled] = false;
}

public OnActivated(iClient)
{
	SDKHook(iClient, SDKHook_PreThinkPost, OnPreThinkPost);
	g_eParkourData[iClient][Parkour_Enabled] = true;
	g_eParkourData[iClient][Grapple_Charge] = GRAPPLE_CHARGE_MAX;
	g_eParkourData[iClient][Grapple_HookEntityRef] = -1;
}

public OnDeactivated(iClient)
{
	g_eParkourData[iClient][Parkour_Enabled] = false;
	SDKUnhook(iClient, SDKHook_PreThinkPost, OnPreThinkPost);
	KillHook(iClient);
}

bool:IsNearWall(iClient)
{
	decl Float:fEyePos[3], Float:fOrigin[3];
	GetClientEyePosition(iClient, fEyePos);
	GetClientAbsOrigin(iClient, fOrigin);
	
	new Float:fEyeHeight = fEyePos[2] - fOrigin[2] - 16.0;
	decl Float:fMins[3];
	fMins[0] = -TRACE_HULL_RADIUS;
	fMins[1] = -TRACE_HULL_RADIUS;
	fMins[2] = -fEyeHeight;
	decl Float:fMaxs[3];
	fMaxs[0] = TRACE_HULL_RADIUS;
	fMaxs[1] = TRACE_HULL_RADIUS;
	fMaxs[2] = 0.0;
	
	TR_TraceHullFilter(fEyePos, fEyePos, fMins, fMaxs, MASK_PLAYERSOLID, TraceFilter_DontHitPlayers);
	
	if(TR_DidHit())
	{
		return true;
	}
	else
	{
		return false;
	}
}


public bool:TraceFilter_DontHitPlayers(iEnt, iMask, any:iData)
{
	if(1 <= iEnt <= MaxClients)
		return false;
	
	return true;
}

public OnPreThinkPost(iClient)
{
	new iButtons = GetClientButtons(iClient);
	
	OnGrapple(iClient, iButtons & IN_ATTACK);

	if(iButtons & IN_ATTACK2)
	{
		OnAttack2(iClient);
	}

	//PrintHintText(iClient, "%f", g_eParkourData[iClient][Grapple_Charge]);
	
	if(GetEntityFlags(iClient) & FL_ONGROUND)
	{
		g_eParkourData[iClient][WallJump_JumpsSinceGround] = 0;
	}
}


OnGrapple(iClient, bState)
{
	if(bState && !g_eParkourData[iClient][Grapple_Expired])
	{
		new iHook = EntRefToEntIndex(g_eParkourData[iClient][Grapple_HookEntityRef]);
		if(iHook > 0)
		{
			if(g_eParkourData[iClient][Grapple_Hooked])
			{
				decl Float:fClientPos[3], Float:fEyeAngles[3], Float:fGrappleEntPos[3];
				GetClientEyePosition(iClient, fClientPos);
				GetClientEyeAngles(iClient, fEyeAngles);
				GetEntPropVector(iHook, Prop_Send, "m_vecOrigin", fGrappleEntPos);
				
				decl Float:fClientVel[3], Float:fHookDir[3];
				GetEntPropVector(iClient, Prop_Data, "m_vecVelocity", fClientVel);
				
				SubtractVectors(fGrappleEntPos, fClientPos, fHookDir);
				NormalizeVector(fHookDir, fHookDir);
				new Float:fSpeedTowardsHook = GetVectorDotProduct(fClientVel, fHookDir);
				
				if (fSpeedTowardsHook < GRAPPLE_PULL_MAX)
				{
					new Float:fSpeedToAdd = GRAPPLE_PULL_ACCEL;
					if(fSpeedTowardsHook + fSpeedToAdd > GRAPPLE_PULL_MAX)
					{
						fSpeedToAdd = GRAPPLE_PULL_MAX - fSpeedTowardsHook;
					}
					
					ScaleVector(fHookDir, fSpeedToAdd);
					AddVectors(fClientVel, fHookDir, fClientVel);
					TeleportEntity(iClient, NULL_VECTOR, NULL_VECTOR, fClientVel);
				}
				
				HookCharge(iClient, GRAPPLE_CHARGE_USE);
				
				decl iColor[4];
				GetChargeColor(iClient, iColor);
				
				GetAngleVectors(fEyeAngles, fEyeAngles, NULL_VECTOR, NULL_VECTOR);
				ScaleVector(fEyeAngles, 200.0);
				AddVectors(fClientPos, fEyeAngles, fClientPos);
				
				TE_SetupBeamPoints(fClientPos, fGrappleEntPos, g_Sprite, 0, 0, 0, 0.1, 2.0, 2.0, 10, 0.0, iColor, 0);
				TE_SendToClient(iClient);
				
				HookCharge(iClient, GRAPPLE_CHARGE_USE);
			}
		}
		else
		{
			iHook = CreateHook(iClient);
			if(!iHook)
				return;
			
			g_eParkourData[iClient][Grapple_HookEntityRef] = EntIndexToEntRef(iHook);
			
			decl Float:fEyePos[3], Float:fVelocity[3];
			GetClientEyePosition(iClient, fEyePos);
			GetClientEyeAngles(iClient, fVelocity);
			GetAngleVectors(fVelocity, fVelocity, NULL_VECTOR, NULL_VECTOR);
			ScaleVector(fVelocity, GRAPPLE_HOOK_SPEED);
			TeleportEntity(iHook, fEyePos, NULL_VECTOR, fVelocity);
			
			decl iColor[4];
			GetChargeColor(iClient, iColor);
			
			TE_SetupBeamFollow(iHook, g_Sprite, 0, 1.0, 5.0, 5.0, 10, iColor);
			TE_SendToClient(iClient);
		}
	}
	else if(bState)
	{
		HookCharge(iClient, GRAPPLE_CHARGE_REGEN);
	}
	else
	{
		HookCharge(iClient, GRAPPLE_CHARGE_REGEN);
		
		KillHook(iClient);
		
		if(g_eParkourData[iClient][Grapple_Expired])
			g_eParkourData[iClient][Grapple_Expired] = false;
	}
}

CreateHook(iClient)
{
	new iEnt = CreateEntityByName("smokegrenade_projectile");
	if(iEnt < 1 || !IsValidEntity(iEnt))
		return 0;
	
	InitHook(iClient, iEnt);
	return iEnt;
}

KillHook(iClient)
{
	new iHook = EntRefToEntIndex(g_eParkourData[iClient][Grapple_HookEntityRef]);
	if(iHook > 0)
		AcceptEntityInput(iHook, "KillHierarchy");
	
	g_eParkourData[iClient][Grapple_Hooked] = false;
	g_eParkourData[iClient][Grapple_HookEntityRef] = -1;
}

HookCharge(iClient, Float:fAmount)
{
	if(GetEntityFlags(iClient) & FL_ONGROUND && fAmount > 0.0)
	{
		g_eParkourData[iClient][Grapple_Charge] += 10.0 * fAmount;
	}
	else
	{
		g_eParkourData[iClient][Grapple_Charge] += fAmount;
	}

	if (g_eParkourData[iClient][Grapple_Charge] > GRAPPLE_CHARGE_MAX)
	{
		g_eParkourData[iClient][Grapple_Charge] = GRAPPLE_CHARGE_MAX;
	}
	else if (g_eParkourData[iClient][Grapple_Charge] <= 0.0)
	{
		g_eParkourData[iClient][Grapple_Charge] = 0.0;
		KillHook(iClient);
		g_eParkourData[iClient][Grapple_Expired] = true;	
	}
}

GetChargeColor(iClient, iResult[4])
{
	new iGreen = RoundToFloor((255 / GRAPPLE_CHARGE_MAX) * g_eParkourData[iClient][Grapple_Charge]);
	new iRed = RoundToFloor(255.0 - (255 / GRAPPLE_CHARGE_MAX) * g_eParkourData[iClient][Grapple_Charge]);
	
	if(iRed < 0)
	{
		iRed = 0;
	}
	if(iGreen < 0)
	{
		iGreen = 0;
	}
	
	new iColor[4] = {255, 255, 0, 255};
	iColor[0] = iRed;
	iColor[1] = iGreen;
	
	iResult = iColor;
}

InitHook(iClient, iHook)
{
	DispatchSpawn(iHook);
	
	SetEntityMoveType(iHook, MOVETYPE_FLYGRAVITY);
	SetEntProp(iHook, Prop_Send, "m_CollisionGroup", ROCKET_COLLISION_GROUP);
	SetEntProp(iHook, Prop_Data, "m_nSolidType", SOLID_NONE);
	SetEntProp(iHook, Prop_Send, "m_usSolidFlags", FSOLID_NOT_SOLID | FSOLID_TRIGGER);
	SetEntPropEnt(iHook, Prop_Send, "m_hOwnerEntity", iClient);
	
	SetEntProp(iHook, Prop_Data, "m_nSurroundType", USE_SPECIFIED_BOUNDS);
	SetEntPropFloat(iHook, Prop_Data, "m_flRadius", 0.0);
	SetEntProp(iHook, Prop_Data, "m_triggerBloat", 0);
	
	SetEntPropVector(iHook, Prop_Send, "m_vecMins", g_fRocketMins);
	SetEntPropVector(iHook, Prop_Send, "m_vecMaxs", g_fRocketMaxs);
	
	SetEntPropVector(iHook, Prop_Send, "m_vecSpecifiedSurroundingMins", g_fRocketMins);
	SetEntPropVector(iHook, Prop_Send, "m_vecSpecifiedSurroundingMaxs", g_fRocketMaxs);
	
	SetEntPropVector(iHook, Prop_Data, "m_vecSurroundingMins", g_fRocketMins);
	SetEntPropVector(iHook, Prop_Data, "m_vecSurroundingMaxs", g_fRocketMaxs);
	
	SDKHook(iHook, SDKHook_StartTouchPost, OnHookStartTouchPost);
}

public OnHookStartTouchPost(iHook, iOther)
{
	new iOwner = GetEntPropEnt(iHook, Prop_Send, "m_hOwnerEntity");
	g_eParkourData[iOwner][Grapple_Hooked] = true;
	
	TeleportEntity(iHook, NULL_VECTOR, NULL_VECTOR, Float:{0.0, 0.0, 0.0});
	SetEntityMoveType(iHook, MOVETYPE_NONE);
}

OnAttack2(iClient)
{
	if((GetEngineTime() - g_eParkourData[iClient][WallJump_LastJumpTime] >= WALLJUMP_COOLDOWN_BASE)
	&& IsNearWall(iClient)
	&& (g_eParkourData[iClient][WallJump_JumpsSinceGround] < WALLJUMP_MAX_IN_AIR))
	{
		g_eParkourData[iClient][WallJump_JumpsSinceGround]++;
		
		decl Float:fNewVel[3], Float:fVelocity[3], Float:fEyeAngles[3];
		GetEntPropVector(iClient, Prop_Data, "m_vecVelocity", fVelocity);
		GetClientEyeAngles(iClient, fEyeAngles);
		GetAngleVectors(fEyeAngles, fNewVel, NULL_VECTOR, NULL_VECTOR);
		
		ScaleVector(fNewVel, 200.0);
		
		if(fNewVel[2] > 0)
		{
			fNewVel[2] += 300.0;
		}
		else
		{
			fNewVel[2] = 0.0;
		}
		
		fVelocity[2] = 0.0;
		AddVectors(fVelocity, fNewVel, fNewVel);
		TeleportEntity(iClient, NULL_VECTOR, NULL_VECTOR, fNewVel);
		g_eParkourData[iClient][WallJump_LastJumpTime] = GetEngineTime();
		
		HookCharge(iClient, GRAPPLE_CHARGE_WALLJUMP);
	}
}