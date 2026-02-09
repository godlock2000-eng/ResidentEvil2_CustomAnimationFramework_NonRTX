# Custom Animation Framework (CAF) for RE2 Remake

Event-driven custom animation framework for Resident Evil 2 Remake via REFramework. Add custom animations using JSON manifests and binary animation files -- no engine code needed. Includes DynamicMotionBank playback, root motion, layer overlays, chain/combo system, EventBus, and Python toolchain for generating .motlist.85/.motbank.1 binaries. Ships with RE3-style dodge pack.

## Quick Start

1. Install [REFramework](https://www.nexusmods.com/residentevil22019/mods/11)
2. Copy `framework/reframework/` and `framework/natives/` into your RE2 game folder
3. Launch game, press Insert to open REFramework menu
4. Find "CAF Mod API v1.0" -- the RE3 Dodge Pack should appear under "Loaded Mods"
5. Press V + WASD to dodge

## Project Structure

```
docs/                          -- Research & format documentation
framework/
  reframework/
    autorun/
      CAF_ModAPI.lua           -- Main framework (~1100 lines)
      CAF_ModAPI/API.lua       -- Requireable API module
      CAF_re3_dodge_settings.lua -- RE3 dodge settings companion
      CAF_NativeDodge.lua      -- Earlier standalone dodge (superseded by ModAPI)
      CAF_MotionLoader.lua     -- Multi-actor / paired animation loader
      CustomAnimFramework.lua  -- Original bone-override prototype
    data/
      CAF_mods/re3_dodge/      -- RE3 dodge mod package (manifest.json)
  natives/x64/
    CAF_custom/                -- .motlist.85 and .motbank.1 animation binaries
tools/
  mot_writer.py                -- JSON to .motlist.85 converter
  motbank_writer.py            -- .motbank.1 wrapper generator
  dump_to_motlist.py           -- Bone dump to .motlist.85 converter
  validate_against_real.py     -- .motlist.85 binary validator / hex dumper
  blender_anim_exporter.py     -- Blender add-on: export armature anims as JSON
  resolve_bone_names.py        -- Cross-reference bone hashes between RE2/RE3
  DodgeDumperV4.lua            -- RE3 bone capture (single recording, named format)
  DodgeDumperV5.lua            -- RE3 bone capture (single + continuous w/ auto-detect)
  RE2BoneHashDumper.lua        -- Dump RE2 joint names, indices, and hashes
  RE3BoneHashDumper.lua        -- Dump RE3 joint names, indices, and hashes
wiki/
  index.html                   -- Self-contained wiki with full documentation
```

## Documentation

Open `wiki/index.html` in a browser for the full wiki, covering:
- User guide (installation, controls, settings)
- How it works (architecture, pipeline, playback engine, events)
- Modder guide (creating mod packages, manifest.json reference, Python tools)
- API reference (playback, events, registration, utilities)
- Technical reference (binary format, DynamicMotionBank, FSM control, bone mapping)
- Development history and lessons learned

## Creating Mod Packages

1. Create animation data (capture from game or export from Blender)
2. Convert to .motlist.85 with `dump_to_motlist.py` or `mot_writer.py`
3. Create .motbank.1 wrapper with `motbank_writer.py`
4. Write a `manifest.json` defining animations and event bindings
5. Place files in the game folder and launch

See the wiki or `framework/reframework/data/CAF_mods/re3_dodge/` for a complete example.

## External Resources

These tools and references were used during development and are useful for advanced modders:

- **[RE-Engine-010-Templates](https://github.com/alphazolam/RE-Engine-010-Templates)** by alphazolam -- 010 Editor binary templates for RE Engine file formats, including `RE_Engine_motlist.bt`, `RE_Engine_motbank.bt`, and `RE_CLIP_TML.bt`. Essential for inspecting and understanding .motlist.85/.motbank.1 binary structure. Not included in this repo; download from alphazolam's GitHub.
- **[REFramework](https://github.com/praydog/REFramework)** by praydog -- The scripting framework this project runs on. Generates `il2cpp_dump.json` on first launch, which contains all game type definitions (classes, methods, fields). Search this dump for `via.motion.Motion`, `via.motion.DynamicMotionBank`, `via.motion.TreeLayer`, etc. to discover the animation APIs used by CAF.
- **[EMV-Engine](https://github.com/alphazolam/EMV-Engine)** by alphazolam -- REFramework Lua scripts for RE Engine games, includes MotionBank/MotionList browsing utilities.

## License

MIT
