/**
 * Weapon model overrides.
 * 
 * Provides three attributes "viewmodel override", "worldmodel override",
 * and "clientmodel override".  Attribute values are full paths to models (include "models/"
 * prefix).
 * 
 * - "viewmodel override" is used exclusively for the owning player's view.
 * - "worldmodel override" is used for other players' views, dropped weapons, and attached
 * sappers.
 * - "clientmodel override" can be used in place of both if they share the same model, and will
 * take priority.
 *
 * Okay, so this is a rather awful mix of the main and lighting fix branch code. I got the worldmodel to not show,
 * and the weapon to not be attached when dead. Still trying to figure out how to properly -
 * convert over the sniper fix, since i have a surface level understanding of sourcepawn.
 * a lot of these changes are guesses based on what i'd do in lua, considering my -
 * "expertise" is in making garrys mod addons. what im doing here is the equivalent of throwing a rock and seeing -
 * where it lands.
 */
#pragma semicolon 1
#include <sourcemod>

#include <sdktools>
#include <sdkhooks>

#pragma newdecls required

#include <tf_custom_attributes>
#include <stocksoup/tf/entity_prop_stocks>
#include <stocksoup/tf/econ>
#include <tf_econ_data>

#include <tf2utils>

#define EF_NODRAW (1 << 5)

#define MODEL_NONE_ACTIVE    0
#define MODEL_VIEW_ACTIVE    (1 << 0)
#define MODEL_ARM_ACTIVE     (1 << 1)
#define MODEL_WORLD_ACTIVE   (1 << 2)
#define MODEL_OFFHAND_ACTIVE (1 << 3)

#define TF_ITEM_DEFINDEX_GUNSLINGER 142

bool g_bIgnoreWeaponSwitch[MAXPLAYERS + 1];


int g_iLastViewmodelRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };

int g_iLastWorldModelRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };


int g_iLastOffHandViewmodelRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };

public void OnMapStart() {
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i)) {
			OnClientPutInServer(i);
		}
	}
	HookEvent("player_death", OnPlayerDeath);
	HookEvent("post_inventory_application", OnInventoryAppliedPre, EventHookMode_Pre);
	HookEvent("player_sapped_object", OnObjectSappedPost);
}

public void OnPluginEnd() {
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i)) {
			DetachVMs(i);
		}
	}
}

public void OnClientPutInServer(int client) {
	SDKHook(client, SDKHook_Spawn, OnPlayerSpawnPre);
	SDKHook(client, SDKHook_SpawnPost, OnPlayerSpawnPost);
	SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
}

public void OnEntityCreated(int entity, const char[] className) {
	if (StrEqual(className, "tf_dropped_weapon")) {
		SDKHook(entity, SDKHook_SpawnPost, OnDroppedWeaponSpawnPost);
	}
}

/**
 * Hides our original weapon in local third-person if we have a worldmodel assigned.
 */
public void TF2_OnConditionAdded(int client, TFCond condition) {
	if (condition != TFCond_Taunting || !IsValidEntity(g_iLastViewmodelRef[client])) {
		return;
	}
	
	int weapon = TF2_GetClientActiveWeapon(client);
	if (IsValidEntity(weapon)) {
		SetEntityRenderMode(weapon, RENDER_TRANSCOLOR);
		SetEntityRenderColor(weapon, .a = 0);
	}
}

/**
 * Rehides the original weapon in local first-person if we have a viewmodel assigned.
 */
public void TF2_OnConditionRemoved(int client, TFCond condition) {
	if (condition != TFCond_Taunting || !IsValidEntity(g_iLastViewmodelRef[client])) {
		return;
	}
	
	int weapon = TF2_GetClientActiveWeapon(client);
	if (IsValidEntity(weapon)) {
		SetEntityRenderMode(weapon, RENDER_NORMAL);
		SetEntProp(weapon, Prop_Send, "m_bBeingRepurposedForTaunt", true);
	}
}

/**
 * Sets the world model of a dropped weapon.
 */
void OnDroppedWeaponSpawnPost(int weapon) {
	char wm[PLATFORM_MAX_PATH];
	if (TF2CustAttr_GetString(weapon, "clientmodel override", wm, sizeof(wm))
			|| TF2CustAttr_GetString(weapon, "worldmodel override", wm, sizeof(wm))) {
		SetEntityModel(weapon, wm);
		SetWeaponWorldModel(weapon, wm);
	}
}

/**
 * Called when the player's loadout is applied.  Note that other plugins may not have finished
 * applying weapons by this time; however, they should implicitly invoke WeaponSwitchPost
 * (because of GiveNamedItem, etc.) so viewmodels should be correct.
 */
void OnInventoryAppliedPre(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client) {
		return;
	}
	UpdateClientWeaponModel(client);
	
	/**
	 * start processing weapon switches, since other plugins may be equipping new weapons in
	 * post_inventory_application -- and that's still within the player's spawn function call
	 */
	g_bIgnoreWeaponSwitch[client] = false;
}

/**
 * When the player is spawning, the game spends some time checking the player's weapons for
 * validity.  This fires off a bunch of weapon switch events, so we don't bother checking early
 * in the function.
 */
Action OnPlayerSpawnPre(int client) {
	g_bIgnoreWeaponSwitch[client] = true;
	return Plugin_Continue;
}

void OnPlayerSpawnPost(int client) {
	g_bIgnoreWeaponSwitch[client] = false;
}

void OnWeaponSwitchPost(int client, int weapon) {
	if (!g_bIgnoreWeaponSwitch[client]) {
		UpdateClientWeaponModel(client);
	}
 }

/**
 * Called on weapon switch.  Detaches any old viewmodel overrides and attaches replacements.
 */
void UpdateClientWeaponModel(int client) {
	DetachVMs(client);
	
	int weapon = TF2_GetClientActiveWeapon(client);
	if (!IsValidEntity(weapon)) {
		return;
	}
	
	int bitsActiveModels = MODEL_NONE_ACTIVE;
	
	char cm[PLATFORM_MAX_PATH];
	TF2CustAttr_GetString(weapon, "clientmodel override", cm, sizeof(cm));
	
	char vm[PLATFORM_MAX_PATH];
	if (TF2CustAttr_GetString(weapon, "viewmodel override", vm, sizeof(vm), cm)
			&& FileExists(vm, true)) {
		// override viewmodel by attaching arm and weapon viewmodels
		PrecacheModel(vm);
		
		int weaponvm = TF2_SpawnWearableViewmodel();
		
		SetEntityModel(weaponvm, vm);
		TF2Util_EquipPlayerWearable(client, weaponvm);
		
		g_iLastViewmodelRef[client] = EntIndexToEntRef(weaponvm);
		bitsActiveModels |= MODEL_VIEW_ACTIVE;
	}
	
	char wm[PLATFORM_MAX_PATH];
	if (TF2CustAttr_GetString(weapon, "worldmodel override", wm, sizeof(wm), cm)) {
		// this allows other players to see the given weapon with the correct model
		SetWeaponWorldModel(weapon, wm);
		
		// the following shows the weapon in third-person, as m_nModelIndexOverrides is messy
		int weaponwm = TF2_SpawnWearable();
		SetEntityModel(weaponwm, wm);
		
		TF2Util_EquipPlayerWearable(client, weaponwm);
		g_iLastWorldModelRef[client] = EntIndexToEntRef(weaponwm);
		
		SetEntityRenderMode(weapon, RENDER_TRANSCOLOR);
		SetEntityRenderColor(weapon, 0, 0, 0, 0);
		
		bitsActiveModels |= MODEL_WORLD_ACTIVE;
	}
	
	if (TF2_GetPlayerClass(client) == TFClass_DemoMan && TF2Util_IsEntityWeapon(weapon)
			&& TF2Util_GetWeaponSlot(weapon) == TFWeaponSlot_Melee) {
		// display shield if player has their melee weapon out on demoman
		int shield = TF2Util_GetPlayerLoadoutEntity(client, 1);
		char ohvm[PLATFORM_MAX_PATH];
		if (IsValidEntity(shield) && TF2Util_IsEntityWearable(shield)
				&& TF2CustAttr_GetString(shield, "clientmodel override", ohvm, sizeof(ohvm))
				&& FileExists(ohvm, true)) {
			PrecacheModel(ohvm);
			
			int offhandwearable = TF2_SpawnWearableViewmodel();
			
			SetEntityModel(offhandwearable, ohvm);
			TF2Util_EquipPlayerWearable(client, offhandwearable);
			
			g_iLastOffHandViewmodelRef[client] = EntIndexToEntRef(offhandwearable);
			
			SetEntityModel(shield, ohvm);
			
			bitsActiveModels |= MODEL_OFFHAND_ACTIVE;
		}
	}
	
	// if we didn't touch any viewmodels, there's nothing else we need to do
	if (bitsActiveModels & (MODEL_VIEW_ACTIVE | MODEL_OFFHAND_ACTIVE) == 0) {
		return;
	}
	
	/**
	 * this prevents the weapon from being drawn in first-person without modifying rendering
	 * properties that cause lighting quirks (setting VM to nodraw and weapon to transparent)
	 */
	SetEntProp(weapon, Prop_Send, "m_bBeingRepurposedForTaunt", true);
	
	if (bitsActiveModels & MODEL_VIEW_ACTIVE == 0) {
		// we're rendering a custom offhand model & we didn't create a custom weapon viewmodel;
		// we need to render the original one for that weapon
		int itemdef = GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex");
		if (!TF2Econ_GetItemDefinitionString(itemdef, "model_player", vm, sizeof(vm))) {
			return;
		}
		
		PrecacheModel(vm);
		
		int weaponvm = TF2_SpawnWearableViewmodel();
		
		SetEntityModel(weaponvm, vm);
		TF2Util_EquipPlayerWearable(client, weaponvm);
		
		g_iLastViewmodelRef[client] = EntIndexToEntRef(weaponvm);
		
		bitsActiveModels |= MODEL_VIEW_ACTIVE;
	}
}

/**
 * Destroys wearable worldmodels on death so ragdolls aren't holding them.
 */
void OnPlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client) {
		MaybeRemoveWearable(client, g_iLastWorldModelRef[client]);
	}
}

/**
 * Allows the use of custom models on sappers attached to buildings.
 */
void OnObjectSappedPost(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!IsValidEntity(client)) {
		return;
	}
	
	int sapper = GetPlayerWeaponSlot(client, TFWeaponSlot_Secondary);
	if (!IsValidEntity(sapper)) {
		return;
	}
	
	char wm[PLATFORM_MAX_PATH];
	if (TF2CustAttr_GetString(sapper, "clientmodel override", wm, sizeof(wm))
			|| TF2CustAttr_GetString(sapper, "worldmodel override", wm, sizeof(wm))) {
		int attachedSapper = event.GetInt("sapperid");
		SetAttachedSapperModel(attachedSapper, wm);
	}
}

bool SetWeaponWorldModel(int weapon, const char[] worldmodel) {
	if (!FileExists(worldmodel, true)) {
		return false;
	}
	
	int model = PrecacheModel(worldmodel);
	if (HasEntProp(weapon, Prop_Send, "m_iWorldModelIndex")) {
		SetEntProp(weapon, Prop_Send, "m_iWorldModelIndex", model);
	}
	
	/**
	 * setting m_nModelIndexOverrides causes firing animations to break, but prevents the
	 * weapon from showing up with the overwritten model in taunts
	 * 
	 * to display the overwritten world model on dropped items see OnDroppedWeaponSpawnPost
	 */
	for (int i = 1; i < GetEntPropArraySize(weapon, Prop_Send, "m_nModelIndexOverrides"); i++) {
		// SetEntProp(weapon, Prop_Send, "m_nModelIndexOverrides", model, .element = i);
	}
	return true;
}

/**
 * Sets the model on the given building-attached sapper.
 */
bool SetAttachedSapperModel(int sapper, const char[] worldmodel) {
	if (!FileExists(worldmodel, true)) {
		return false;
	}
	SetEntityModel(sapper, worldmodel);
	return true;
}

/**
 * Detaches any custom viewmodels on the client and displays the original viewmodel.
 */
void DetachVMs(int client) {
	for (int i; i < 7; i++) {
		int weapon = GetPlayerWeaponSlot(client, i);
		if (IsValidEntity(weapon)) {
			SetEntProp(weapon, Prop_Send, "m_bBeingRepurposedForTaunt", false);
		}
	}
	
	MaybeRemoveWearable(client, g_iLastViewmodelRef[client]);
	
	if (MaybeRemoveWearable(client, g_iLastWorldModelRef[client])) {
		int activeWeapon = TF2_GetClientActiveWeapon(client);
		if (IsValidEntity(activeWeapon)) {
			SetEntityRenderMode(activeWeapon, RENDER_NORMAL);
		}
	}
	
	MaybeRemoveWearable(client, g_iLastOffHandViewmodelRef[client]);
}

bool MaybeRemoveWearable(int client, int wearable) {
	if (IsValidEntity(wearable)) {
		// the below function does not take entrefs.
		TF2_RemoveWearable(client, EntRefToEntIndex(wearable));
		return true;
	}
	return false;
}

/**
 * Creates a wearable viewmodel.
 * This sets EF_BONEMERGE | EF_BONEMERGE_FASTCULL when equipped.
 */
stock int TF2_SpawnWearableViewmodel() {
	int wearable = CreateEntityByName("tf_wearable_vm");
	
	if (IsValidEntity(wearable)) {
		SetEntProp(wearable, Prop_Send, "m_iItemDefinitionIndex", DEFINDEX_UNDEFINED);
		DispatchSpawn(wearable);
	}
	return wearable;
}