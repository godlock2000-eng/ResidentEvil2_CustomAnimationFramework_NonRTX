 1. Primary Class Containing get_AxisL and get_Button Methods

       The via.hid.GamePadDevice class is the concrete implementation you need. This is the primary type for gamepad input methods:

       - Type Name: via.hid.GamePadDevice
       - Parent Class: via.hid.NativeDeviceBase
       - Type ID: 15556
       - Flags: Public | BeforeFieldInit | NativeType | NativeCtor | ManagedVTable

       2. Key Methods in via.hid.GamePadDevice

       The class contains the following input methods:
       - get_AxisL() (id: 17306) → returns via.vec2 (left analog stick position)
       - get_AxisR() (id: 17308) → returns via.vec2 (right analog stick position)
       - get_Button() (id: 17296) → returns via.hid.GamePadButton (current button state)
       - get_ButtonDown() (id: 17298) → returns via.hid.GamePadButton (buttons pressed this frame)
       - get_ButtonUp() (id: 17300) → returns via.hid.GamePadButton (buttons released this frame)
       - get_AnalogL() (id: 17310) → returns System.Single (left trigger value)
       - get_AnalogR() (id: 17312) → returns System.Single (right trigger value)
       - get_RawAxisL() (id: 17302) → returns via.vec2
       - get_RawAxisR() (id: 17304) → returns via.vec2

       3. Related Classes

       via.hid.GamePadState (id: 56074) - Stores buffered gamepad state data
       - Also has get_AxisL(), get_AxisR(), get_Button() methods
       - Slightly different IDs than GamePadDevice
       - Has get_AsyncBufferedState() → via.hid.GamePadState[]

       via.hid.GamePadButton (enum) - Button identifier enum
       - Contains: A, B, X, Y, LStickPush, RStickPush, LSL, LSR, RSL, RSR, LTrigTop, LTrigBottom, RTrigTop, RTrigBottom, LUp, LDown, LLeft, LRight, RUp, RDown, RLeft, RRight, CLeft, CCenter, CRight,
       PlatformHome, Decide, Cancel, etc.

       4. How to Get an Instance (Singleton Access)

       From the Backdash.lua example (line 93-95):
       local gp_singleton = sdk.get_native_singleton("via.hid.Gamepad")
       local gp_typedef = sdk.find_type_definition("via.hid.GamePad")
       local gamepad = sdk.call_native_func(gp_singleton, gp_typedef, "getMergedDevice", 0)

       Key points:
       - Singleton Class: via.hid.GamePad (note: abstract static class with static methods, NOT the Device class)
       - Singleton Access: sdk.get_native_singleton("via.hid.Gamepad") (native singleton)
       - Method to get merged device: getMergedDevice(0) - merges all connected controllers
       - Returns: via.hid.GamePadDevice instance

       5. Alternative Access Method

       Via the InputSystem singleton (managed):
       app.ropeway.InputSystem
       - Inherited from: app.ropeway.RopewaySingletonBehaviorRoot`1<app.ropeway.InputSystem>
       - Property: ActiveUserDevice (get_ActiveUserDevice) → via.hid.GamePadDevice

       And the InputUnit component:
       app.ropeway.InputUnit
       - Inherited from: app.ropeway.RopewayBehaviorRoot
       - Properties: Device (get_Device) → via.hid.GamePadDevice

       6. Usage Example (from Backdash.lua)

       -- Get the merged gamepad device (combines all connected controllers)
       local gp_singleton = sdk.get_native_singleton("via.hid.Gamepad")
       local gp_typedef = sdk.find_type_definition("via.hid.GamePad")
       local gamepad = sdk.call_native_func(gp_singleton, gp_typedef, "getMergedDevice", 0)

       -- Check button state
       local button_bits = gamepad:get_Button()

       -- Check analog sticks
       local left_stick = gamepad:get_AxisL()  -- returns via.vec2 with x, y components
       local right_stick = gamepad:get_AxisR()

       -- Check triggers
       local left_trigger = gamepad:get_AnalogL()
       local right_trigger = gamepad:get_AnalogR()

       7. Parent Class Hierarchy (for get_AxisL id 2318)

       The property belongs to via.hid.GamePadDevice with parent type via.hid.NativeDeviceBase

       8. Summary

       - Exact Type Name: via.hid.GamePadDevice
       - How to Access: Via via.hid.GamePad.getMergedDevice(0) (static method call on native singleton)
       - Instance Type: Concrete class (not enum/struct)
       - Methods: get_AxisL, get_AxisR, get_Button, get_ButtonDown, get_ButtonUp, get_AnalogL, get_AnalogR, and more
       
              All paths in this response are absolute paths as specified.