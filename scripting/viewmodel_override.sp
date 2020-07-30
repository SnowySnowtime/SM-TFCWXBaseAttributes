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
 */
#pragma semicolon 1
#include <sourcemod>

#include <sdktools>
#include <sdkhooks>

#pragma newdecls required

#include <tf2wearables>
#include <tf_custom_attributes>
#include <stocksoup/tf/entity_prop_stocks>
#include <stocksoup/tf/econ>

#define EF_BONEMERGE (1 << 0)
#define EF_NODRAW (1 << 5)
#define EF_BONEMERGE_FASTCULL (1 << 7)

int g_iLastViewmodelRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
int g_iLastArmModelRef[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };

public void OnMapStart() {
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i)) {
			OnClientPutInServer(i);
		}
	}
	
	HookEvent("post_inventory_application", OnInventoryAppliedPost);
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
	SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
}

public void OnEntityCreated(int entity, const char[] className) {
	if (StrEqual(className, "tf_dropped_weapon")) {
		SDKHook(entity, SDKHook_SpawnPost, OnDroppedWeaponSpawnPost);
	}
}

/**
 * Sets the world model of a dropped weapon.
 */
public void OnDroppedWeaponSpawnPost(int weapon) {
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
public void OnInventoryAppliedPost(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client) {
		return;
	}
	int activeWeapon = TF2_GetClientActiveWeapon(client);
	if (IsValidEntity(activeWeapon)) {
		OnWeaponSwitchPost(client, activeWeapon);
	}
}

/**
 * Called on weapon switch.  Detaches any old viewmodel overrides and attaches replacements.
 */
public void OnWeaponSwitchPost(int client, int weapon) {
	DetachVMs(client);
	
	char cm[PLATFORM_MAX_PATH];
	TF2CustAttr_GetString(weapon, "clientmodel override", cm, sizeof(cm));
	
	char vm[PLATFORM_MAX_PATH];
	strcopy(vm, sizeof(vm), cm);
	if ((strlen(vm) || TF2CustAttr_GetString(weapon, "viewmodel override", vm, sizeof(vm)))
			&& FileExists(vm, true)) {
		// override viewmodel by attaching arm and weapon viewmodels
		PrecacheModel(vm);
		
		int weaponvm = TF2_SpawnWearableViewmodel();
		
		SetEntityModel(weaponvm, vm);
		TF2_EquipPlayerWearable(client, weaponvm);
		
		g_iLastViewmodelRef[client] = EntIndexToEntRef(weaponvm);
		
		char armvmPath[PLATFORM_MAX_PATH];
		if (GetArmViewModel(client, armvmPath, sizeof(armvmPath))) {
			// armvmPath might not be precached on the server
			// mainly an issue with the gunslinger variation of the arm model
			PrecacheModel(armvmPath);
			
			int armvm = TF2_SpawnWearableViewmodel();
			
			SetEntityModel(armvm, armvmPath);
			TF2_EquipPlayerWearable(client, armvm);
			
			g_iLastArmModelRef[client] = EntIndexToEntRef(armvm);
		}
		
		int clientView = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
		SetEntProp(clientView, Prop_Send, "m_fEffects", EF_NODRAW);
	}
	
	char wm[PLATFORM_MAX_PATH];
	strcopy(wm, sizeof(wm), cm);
	if (strlen(wm) || TF2CustAttr_GetString(weapon, "worldmodel override", wm, sizeof(wm))) {
		SetWeaponWorldModel(weapon, wm);
	}
}

/**
 * Allows the use of custom models on sappers attached to buildings.
 */
public void OnObjectSappedPost(Event event, const char[] name, bool dontBroadcast) {
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
	 * setting m_nModelIndexOverrides[0] causes firing animations to break, but prevents the
	 * weapon from showing up with the overwritten model in taunts
	 * 
	 * to display the overwritten world model on dropped items see OnDroppedWeaponSpawnPost
	 */
	for (int i = 1; i < GetEntPropArraySize(weapon, Prop_Send, "m_nModelIndexOverrides"); i++) {
		SetEntProp(weapon, Prop_Send, "m_nModelIndexOverrides", model, .element = i);
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
	int lastViewmodel = EntRefToEntIndex(g_iLastViewmodelRef[client]);
	if (IsValidEntity(lastViewmodel)) {
		TF2_RemoveWearable(client, lastViewmodel);
	}
	int lastArmModel = EntRefToEntIndex(g_iLastArmModelRef[client]);
	if (IsValidEntity(lastArmModel)) {
		TF2_RemoveWearable(client, lastArmModel);
	}
	
	int clientView = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
	if (IsValidEntity(clientView)) {
		SetEntProp(clientView, Prop_Send, "m_fEffects", 0);
	}
}

/**
 * Returns the arm viewmodel for the given client's assigned class.
 */
int GetArmViewModel(int client, char[] buffer, int maxlen) {
	static char armModels[][] = {
		"",
		"models/weapons/c_models/c_scout_arms.mdl",
		"models/weapons/c_models/c_sniper_arms.mdl",
		"models/weapons/c_models/c_soldier_arms.mdl",
		"models/weapons/c_models/c_demo_arms.mdl",
		"models/weapons/c_models/c_medic_arms.mdl",
		"models/weapons/c_models/c_heavy_arms.mdl",
		"models/weapons/c_models/c_pyro_arms.mdl",
		"models/weapons/c_models/c_spy_arms.mdl",
		"models/weapons/c_models/c_engineer_arms.mdl"
	};
	
	TFClassType playerClass = TF2_GetPlayerClass(client);
	
	// kludge: use gunslinger vm if gunslinger is active on engineer
	if (playerClass == TFClass_Engineer) {
		int meleeWeapon = TF2_GetPlayerLoadoutSlot(client, TF2LoadoutSlot_Melee);
		if (IsValidEntity(meleeWeapon) && TF2_GetItemDefinitionIndex(meleeWeapon) == 142) {
			return strcopy(buffer, maxlen, "models/weapons/c_models/c_engineer_gunslinger.mdl");
		}
	}
	
	return strcopy(buffer, maxlen, armModels[ view_as<int>(playerClass) ]);
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