public with sharing class TerryManager {
	
	final String TERRITORY_MODEL_NAME = 'POC X';
	final String TERRITORY_TYPE_DEFAULT = 'Org_Unit';
	
	final String ACCESS_LEVEVL_ACCOUNT = 'Read';
	final String ACCESS_LEVEL_CASE = 'Edit';
	final String ACCESS_LEVEL_OPP = 'None';

	private Territory2Model model = null;


	public TerryManager() {
		
	}

	public void loadModel() {
		List<Territory2Model> models = [select id, name, developerName from Territory2Model where name =:TERRITORY_MODEL_NAME];

		if(!models.isEmpty()) {
			this.model = models[0];
			system.debug('Model found: ' + model);
		} else {
			this.model = new Territory2Model(
				Name = TERRITORY_MODEL_NAME,
				DeveloperName = 'POC_X'
			);
			system.debug('Inserting new Model: ' + model);
			insert this.model;
		}
	}

	private String devName(String name) {
		return name.replace(' ', '_');
	}

	public Map<String,Territory2Type> getTerritoryTypes(Set<String> typeDevNames) {
		Map<String,Territory2Type> types = new Map<String,Territory2Type>();
		for(Territory2Type tt : [select id, MasterLabel, DeveloperName, Priority from
				Territory2Type where DeveloperName in :typeDevNames]) {
			types.put(tt.DeveloperName, tt);
		}
		return types;
	}

	public Territory2 createTerritory(String name, String label, Id modelId, String accountAccessLevel, String caseAccessLevel, String opportunityAccessLevel, String territoryTypeId, String parentTerritoryId) {
		Territory2 t = new Territory2(
			DeveloperName = name,
			Name = label,
			Territory2ModelId = modelId,
			AccountAccessLevel = accountAccessLevel,
			CaseAccessLevel = caseAccessLevel,
			OpportunityAccessLevel = opportunityAccessLevel,
			ParentTerritory2Id = parentTerritoryId,
			Territory2TypeId = territoryTypeId
		);
		system.debug('New Territory2: ' + t);
		return t;
	}

	/*
	* All magic is here. Steps:
	* Queries Users with a Position Code assigned (assuming they are Business Partners)
	* Create a Territory for each new Position Code
	* Assign Users to new Territories
	* Creates Account Assignment rules and link them to Territories
	*/
	public void run() {

		Map<String, User> bpUsers = new Map<String, User>();
		for(User u : [select id, name, Position_Code__c from User where Position_Code__c != null]) {
			bpUsers.put(u.Position_Code__c, u);
		}
		
		system.debug(bpUsers.size() + ' Business Partners found.');

		if(bpUsers.isEmpty()) {
			return;
		}


		loadModel();

		Set<String> positionCodes = new Set<String>();
		for(User bp : bpUsers.values()) {
			if(bp.Position_Code__c != null) {
				positionCodes.add(bp.Position_Code__c);
			}
		}

		Map<String,Territory2> territories = getTerritories(positionCodes);

		//--- CREATE UNEXISTING TERRITORIES
		Map<String,Territory2Type> types = getTerritoryTypes(new Set<String>{TERRITORY_TYPE_DEFAULT});
		List<Territory2> newTerritories = new List<Territory2>();
		for(User bp : bpUsers.values()) {
			if(!territories.containsKey(bp.Position_Code__c) ) {
				newTerritories.add(
					createTerritory(
						bp.Position_Code__c,
						devName(bp.Position_Code__c),
						model.id,
						ACCESS_LEVEVL_ACCOUNT,
						ACCESS_LEVEL_CASE,
						ACCESS_LEVEL_OPP,
						types.get(TERRITORY_TYPE_DEFAULT).Id,
						null
						)
				);
			}
		}

		if(newTerritories.isEmpty()) {
			system.debug('No new Territories to be created.');
			return;
		}
		system.debug('Inserting ' + newTerritories.size() + ' Territories...');
		insert newTerritories;

		//--- ASSIGN USERS TO TERRITORIES
		List<UserTerritory2Association> userAssignments = assignBPToTerritories(newTerritories, bpUsers);
		system.debug('Inserting ' + userAssignments.size() + ' User Territory assignments...');
		insert userAssignments;

		//--- CREATE ACCOUNT RULE ASSIGNMENTS TO TERRITORIES
		List<ObjectTerritory2AssignmentRule> rules2Insert = new List<ObjectTerritory2AssignmentRule>();
		for(Territory2 t : newTerritories) {
			ObjectTerritory2AssignmentRule r = createTMAssignmentRule(ruleName(t.DeveloperName), String.valueOf(Account.sObjectType), t.Territory2ModelId);
			rules2Insert.add(r);
		}
		system.debug('Inserting ' + rules2Insert.size() + ' rules');
		insert rules2Insert;

		Map<String, ObjectTerritory2AssignmentRule> rules = new Map<String, ObjectTerritory2AssignmentRule>();
		for(ObjectTerritory2AssignmentRule r : rules2Insert) {
			rules.put(r.DeveloperName, r);
		}

		//--- CREATE ACCOUNT RULE ASSIGNMENTS ITEMS TO TERRITORIES
		List<ObjectTerritory2AssignmentRuleItem> ruleItems = new List<ObjectTerritory2AssignmentRuleItem>();
		for(Territory2 t : newTerritories) {
			ObjectTerritory2AssignmentRule r = rules.get(devName(ruleName(t.DeveloperName)));
		
			ObjectTerritory2AssignmentRuleItem ri = createTMAssignmentRuleItem(
				String.valueOf(Account.sObjectType)+'.'+String.valueOf(Account.BP_Position_Code__c),
				'equals',
				t.Name,
				r.id,
				1
			);

			ruleItems.add(ri);
		}
		system.debug('Inserting ' + ruleItems.size() + ' rule items');
		insert ruleItems;


		//--- ASSOCIATE RULE TO TERRITORIES
		List<RuleTerritory2Association> ruleAssociations = new List<RuleTerritory2Association>();
		for(Territory2 t : newTerritories) {
			ObjectTerritory2AssignmentRule r = rules.get(devName(ruleName(t.DeveloperName)));

			ruleAssociations.add(
				assignRuleToTerritory(r.id, t.id)
			);
		}
		system.debug('Inserting ' + ruleAssociations.size() + ' rule territory associations');
		insert ruleAssociations;
	}

	private String ruleName(String positionCode) {
		return 'TM Rule ' + positionCode;
	}

	private List<UserTerritory2Association> assignBPToTerritories(List<Territory2> newTerritories, Map<String,User> bpUsers) {
		List<UserTerritory2Association> userAssignments = new List<UserTerritory2Association>();
		for(Territory2 t : newTerritories) {
			User u = bpUsers.get(t.Name);
			userAssignments.add(new UserTerritory2Association(Territory2Id = t.id, UserId = u.id));
		}
		return userAssignments;
	}

	public ObjectTerritory2AssignmentRule createTMAssignmentRule(String name, String objectType, Id modelId) {
		ObjectTerritory2AssignmentRule r = new ObjectTerritory2AssignmentRule(
			MasterLabel = name,
			DeveloperName = devName(name),
			ObjectType = objectType,
			Territory2ModelId = modelId
		);
		return r;
	}

	public ObjectTerritory2AssignmentRuleItem createTMAssignmentRuleItem(String field, String operation, String value, Id ruleId, Integer order) {
		ObjectTerritory2AssignmentRuleItem ri = new ObjectTerritory2AssignmentRuleItem(
			Field = field,
			Operation = operation,
			Value = value,
			SortOrder = order,
			RuleId = ruleId
		);
		return ri;
	}

	private RuleTerritory2Association assignRuleToTerritory(Id ruleId, Id territoryId) {
		RuleTerritory2Association ra = new RuleTerritory2Association(
			Territory2Id = territoryId,
			RuleId = ruleId
		);
		return ra;
	}
	private Map<String,Territory2> getTerritories(Set<String> codes) {
		Map<String,Territory2> territories = new Map<String,Territory2>();
		for(Territory2 t : [select id, Name, DeveloperName from Territory2 where DeveloperName in :codes]) {
			territories.put(t.DeveloperName, t);
		}
		return territories;
	}

	/*
	* ----- NOTES
	* TerritoryType DML not alloed.
	*/		
}