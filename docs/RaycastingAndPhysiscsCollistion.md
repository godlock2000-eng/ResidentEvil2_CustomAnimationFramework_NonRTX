 COMPREHENSIVE RAYCAST & COLLISION QUERY ANALYSIS - RE2 REFramework

       Based on a thorough analysis of il2cpp_dump.json and REFramework Lua example scripts, here are ALL available physics collision and raycast methods accessible from Lua:

       ---
       1. VIA.PHYSICS.SYSTEM - Physics Query Singleton

       Type Path: via.physics.System (static methods)

       Ray Casting Methods:

       - castRay(query: via.physics.CastRayQuery) → via.physics.CastRayResult
         - Parameters: Takes CastRayQuery struct with ray info and filter
         - Returns: CastRayResult with contact points and hit info
         - ID: 42008
       - castRay(query: via.physics.CastRayQuery, result: via.physics.CastRayResult) → void
         - Async-friendly version that populates result output parameter
         - ID: 42009
       - castRayAsync(query: via.physics.CastRayQuery, result: via.physics.CastRayResult) → void
         - Asynchronous ray cast query
         - ID: 42010

       Shape Casting Methods (Sweep Tests):

       - castCapsule(capsule: via.Capsule, start: via.vec3, end: via.vec3, filter_info: via.physics.FilterInfo, result: via.physics.ShapeCastResult) → void
         - Sweeps a capsule shape along a path
         - Parameters: Capsule shape, start position, end position, collision filter, result output
         - ID: 42006
       - castCapsule(capsule: via.Capsule, start: via.vec3, end: via.vec3, options: uint32, filter_info: via.physics.FilterInfo, result: via.physics.ShapeCastResult) → void
         - Extended capsule sweep with options flags
         - ID: 42007
       - castSphere(sphere: via.Sphere, start: via.vec3, end: via.vec3, filter_info: via.physics.FilterInfo, result: via.physics.ShapeCastResult) → void
         - Sweeps a sphere shape along a path
         - ID: 42012
       - castSphere(sphere: via.Sphere, start: via.vec3, end: via.vec3, options: uint32, filter_info: via.physics.FilterInfo, result: via.physics.ShapeCastResult) → void
         - Extended sphere sweep with options
         - ID: 42013
       - castSphereAsync(sphere: via.Sphere, start: via.vec3, end: via.vec3, options: uint32, filterInfo: via.physics.FilterInfo, result: via.physics.ShapeCastResult) → void
         - Asynchronous sphere cast
         - ID: 42014
       - castShape(query: via.physics.ShapeCastQuery, result: via.physics.ShapeCastResult) → void
         - Generic shape cast with query struct
         - ID: 42011

       Overlap/Proximity Tests:

       - closestShape(query: via.physics.ShapeClosestQuery, result: via.physics.ShapeClosestResult) → void
         - Finds closest point between shapes
         - ID: 42017
       - closestSphere(sphere: via.Sphere, options: uint32, filter_info: via.physics.FilterInfo, result: via.physics.ShapeClosestResult) → void
         - Finds closest point for a sphere
         - ID: 42018
       - contact(shapeA: via.physics.ConvexShape, movementA: via.vec3, shapeB: via.physics.ConvexShape, movementB: via.vec3, outputContactPoint: ref via.physics.ContactPoint) → bool
         - Checks if two shapes in motion make contact
         - Returns: Boolean if contact occurs
         - ID: 42019
       - closest(shapeA: via.physics.ConvexShape, shapeB: via.physics.ConvexShape, outputContactPoint: ref via.physics.ContactPoint) → bool
         - Finds closest point between two convex shapes
         - ID: 42016

       Area Queries:

       - getAreaPrimitive(query: via.physics.GetAreaPrimitiveQuery) → via.physics.GetAreaPrimitiveResult
         - Gets area primitive at position
         - ID: 42020
       - getAreaPrimitive(query: via.physics.GetAreaPrimitiveQuery, result: via.physics.GetAreaPrimitiveResult) → void
         - Area query with output parameter
         - ID: 42021

       ---
       2. VIA.PHYSICS.CHARACTERCONTROLLER - Character Movement & Collision

       Type Path: via.physics.CharacterController (instance methods)

       Movement Methods:

       - warp() → void
         - Teleports character to current position, resetting physics
         - Used in NowhereSafe.lua (line 630, 663, 810)
         - ID: 42190
       - updateManual() → void
         - Manually updates character controller physics
         - ID: 42189

       Collision Detection Properties (Get):

       - get_Ground() → bool
         - Returns true if character is touching ground
         - ID: 42233
       - get_Wall() → bool
         - Returns true if character is touching walls
         - ID: 42234
       - get_Ceiling() → bool
         - Returns true if character is touching ceiling
         - ID: 42235
       - get_Jump() → bool
         - Returns true if character can jump
         - ID: 42236

       Physics State Getters:

       - get_Position() → via.vec3
         - Current character position
         - ID: 42217
       - get_GroupId() → int32
         - Character controller's physics group
         - ID: 42193
       - get_BreakCount() → int32
         - Number of breaks in collision response
         - ID: 42211
       - get_LoopCount() → int32
         - Number of physics simulation loops
         - ID: 42209
       - get_OriginalPosition() → via.vec3
         - Position before current update
         - ID: 42218

       Other Methods:

       - reset() → void
         - Resets character controller state
         - ID: 42186
       - resetContactTypes() → void
         - Clears contact information
         - ID: 42187
       - clearHistory() → void
         - Clears movement history
         - ID: 42182

       ---
       3. VIA.PHYSICS.COLLIDERS - Multi-Collider Container

       Type Path: via.physics.Colliders (instance methods)

       Collider Access:

       - getColliders(index: uint32) → via.physics.Collider
         - Gets individual collider by index
         - ID: 41834
       - getCollidersCount() → uint32
         - Gets total number of colliders
         - ID: 41835
       - setColliders(index: uint32, value: via.physics.Collider) → void
         - Sets collider at index
         - ID: 41836
       - setCollidersCount(value: uint32) → void
         - Changes number of colliders
         - ID: 41837

       AABB & Geometry:

       - get_BoundingAabb() → via.AABB
         - Gets bounding box of all colliders
         - ID: 41846
       - calculateBoundingAabb() → via.AABB
         - Recalculates bounding box
         - ID: 41831

       Physics Updates:

       - updateBroadphase() → void
         - Updates broad phase collision detection
         - ID: 41838
       - updateBroadphase(index: uint32) → void
         - Updates broad phase for specific collider
         - ID: 41839
       - updatePose() → void
         - Updates collider positions
         - ID: 41840
       - updatePose(index: uint32) → void
         - Updates pose for specific collider
         - ID: 41841

       Properties:

       - get_Static() → bool
         - Returns if colliders are static
         - ID: 41842
       - set_Static(value: bool) → void
         - Sets static state
         - ID: 41843

       ---
       4. VIA.PHYSICS.COLLIDER - Individual Collider

       Type Path: via.physics.Collider (instance methods)

       Update Methods:

       - updateBroadphase() → void
         - Updates broad phase for this collider
         - ID: 26273
       - updateCollisionFilter() → void
         - Refreshes collision filtering
         - ID: 26274
       - updateCollisionMaterial() → void
         - Updates collision material properties
         - ID: 26275

       Joint Configuration:

       - get_JointNameA() → string
         - Gets first joint name for constraints
         - ID: 26283
       - set_JointNameA(value: string) → void
         - ID: 26284
       - get_JointNameB() → string
         - Gets second joint name for constraints
         - ID: 26285
       - set_JointNameB(value: string) → void
         - ID: 26286

       Collision Resources:

       - get_CollisionFilterResource() → via.physics.CollisionFilterResourceHolder
         - Gets collision filter resource
         - ID: 26279
       - set_CollisionFilterResource(value) → void
         - ID: 26280
       - get_CollisionMaterialResource() → via.physics.CollisionMaterialResourceHolder
         - ID: 26281
       - set_CollisionMaterialResource(value) → void
         - ID: 26282

       ---
       5. VIA.PHYSICS.CASTRAYQUERY - Ray Query Structure

       Type Path: via.physics.CastRayQuery (value type, pass-by-value)

       Setup Methods:

       - setRay(start: via.vec3, end: via.vec3) → void
         - Sets ray from start to end point
         - ID: 41758
       - setRay(ray_origin: via.vec3, ray_direction: via.vec3, ray_distance: float) → void
         - Sets ray using origin, direction, and distance
         - ID: 41759

       Configuration:

       - get_Ray() → via.Ray
         - Gets ray structure
         - ID: 41760
       - get_RayDistance() → float
         - Gets ray maximum distance
         - ID: 41761
       - get_Options() → uint32
         - Gets query options flags
         - ID: 41762
       - set_Options(value: uint32) → void
         - ID: 41763
       - get_FilterInfo() → via.physics.FilterInfo
         - Gets collision filter settings
         - ID: 41764
       - set_FilterInfo(value: via.physics.FilterInfo) → void
         - ID: 41765

       Query Options Control:

       - clearOptions() → void (ID: 41745)
       - disableAllHits() → void (ID: 41746)
       - disableBackFacingTriangleHits() → void (ID: 41747)
       - disableFrontFacingTriangleHits() → void (ID: 41748)
       - disableInsideHits() → void (ID: 41749)
       - disableNearSort() → void (ID: 41750)
       - disableOneHitBreak() → void (ID: 41751)
       - enableAllHits() → void (ID: 41752)
       - enableBackFacingTriangleHits() → void (ID: 41753)
       - enableFrontFacingTriangleHits() → void (ID: 41754)
       - enableInsideHits() → void (ID: 41755)
       - enableNearSort() → void (ID: 41756)
       - enableOneHitBreak() → void (ID: 41757)

       ---
       6. VIA.PHYSICS.CASTRAYRESULT - Ray Query Results

       Type Path: via.physics.CastRayResult (output structure)

       Results Access:

       - getContactCollidable(index: uint32) → via.physics.Collidable
         - Gets collider that was hit at index
         - ID: 27288
       - getContactPoint(index: uint32) → via.physics.ContactPoint
         - Gets contact point details for hit
         - Returns: Point, normal, distance, material info
         - ID: 27289
       - get_NumContactPoints() → uint32
         - Returns number of hits found
         - ID: 27292

       Status:

       - get_Finished() → bool
         - Whether async query completed
         - ID: 27290
       - get_AsyncResult() → via.physics.CastRayResult.Result
         - Async query result status
         - ID: 27291
       - clear() → void
         - Clears result data
         - ID: 27287

       ---
       7. VIA.PHYSICS.FILTERINFO - Collision Filtering

       Type Path: via.physics.FilterInfo (value type)

       Filter Properties:

       - get_Layer() → uint32
         - Physics layer
         - ID: 19383
       - set_Layer(value: uint32) → void
         - ID: 19384
       - get_Group() → uint32
         - Physics group
         - ID: 19385
       - set_Group(value: uint32) → void
         - ID: 19386
       - get_SubGroup() → uint32
         - Sub-group filter
         - ID: 19387
       - set_SubGroup(value: uint32) → void
         - ID: 19388 (not listed but pattern suggests it exists)
       - get_IgnoreSubGroup() → uint32
         - Ignored sub-groups mask
         - ID: 19389
       - set_IgnoreSubGroup(value: uint32) → void
         - ID: 19390
       - get_MaskBits() → uint32
         - Collision mask bits
         - ID: 19391
       - set_MaskBits(value: uint32) → void
         - ID: 19392

       ---
       8. VIA.PHYSICS.CONTACTPOINT - Hit Details

       Type Path: via.physics.ContactPoint (value type returned from queries)

       Contains:
       - Position of contact
       - Surface normal
       - Hit distance
       - Material information
       - Collidable reference

       ---
       REAL-WORLD USAGE EXAMPLES FROM RE2 MODS

       From NowhereSafe.lua (Path Blocking Detection):

       -- Line 738-739: Checking if sight path is clear
       if (self.sensor:isThroughSight(door_tbl.center, pos)) then
           -- Path is visible/unblocked
       end

       -- Line 177-179: Getting Colliders component for collision checking
       local comp = getC(NowhereSafeColliders, "via.physics.Colliders")
       for i=1, comp:getCollidersCount() do
           local col = comp:getColliders(i-1)
           -- Accessing individual colliders
       end

       -- Line 315-320: Checking collision AABB
       if col:get_BoundingAabb():getExtent():length() < 5.0 then
           -- Small collider detected
       end

       -- Line 618: Detecting ground contact
       local contact_count = (self.cc:get_Ground() and 1 or 0) +
                             (self.cc:get_Wall() and 1 or 0) +
                             (self.cc:get_Ceiling() and 1 or 0)

       Suggested Lua Raycast Pattern (Not yet implemented in examples):

       local physics_system = sdk.find_type_definition("via.physics.System")

       -- Create ray query
       local query = sdk.create_instance("via.physics.CastRayQuery"):add_ref()
       query:setRay(player_pos, target_pos)  -- Ray from player to target

       -- Create result struct
       local result = sdk.create_instance("via.physics.CastRayResult"):add_ref()

       -- Execute ray cast
       physics_system:get_method("castRay"):call(nil, query, result)

       -- Check hits
       local num_hits = result:get_NumContactPoints()
       if num_hits > 0 then
           for i=0, num_hits-1 do
               local contact = result:getContactPoint(i)
               local collidable = result:getContactCollidable(i)
               -- Process hit...
           end
       end

       ---
       SUMMARY FOR PATH-BLOCKING DETECTION

       Most Useful Methods for Lua Movement Path Checking:

       1. via.physics.System.castRay() - Primary raycast from point A to B
       2. via.physics.System.castSphere() - Sweep sphere along path (better for char collision)
       3. via.physics.System.castCapsule() - Sweep capsule (most accurate for character height)
       4. via.physics.CharacterController.get_Ground/Wall/Ceiling() - Check current contact
       5. via.physics.CharacterController.warp() - Test position by moving there
       6. via.physics.Colliders.getCollidersCount/getColliders() - Iterate terrain colliders
       7. via.physics.Collider.updateBroadphase() - Refresh collision state