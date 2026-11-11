#!/bin/bash
# macOS 15+; built-in tools only. See README.md before applying.
set -euo pipefail
umask 077
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This script must run on the Mac whose shortcuts you want to change.' >&2
  exit 1
fi
if [[ "${EUID}" == 0 ]]; then
  echo 'Run as your normal macOS user, without sudo.' >&2
  exit 1
fi
/usr/bin/osascript -l JavaScript /dev/stdin "$@" <<'JXA'
ObjC.import('Foundation');
ObjC.import('AppKit');
ObjC.import('CoreFoundation');

function clone(v) { return JSON.parse(JSON.stringify(v)); }
function canonical(v) {
    if (Array.isArray(v)) return v.map(canonical);
    if (v !== null && typeof v === 'object') {
        var r = {};
        Object.keys(v).sort().forEach(function(k) { r[k] = canonical(v[k]); });
        return r;
    }
    return v;
}
function same(a, b) { return JSON.stringify(canonical(a)) === JSON.stringify(canonical(b)); }
function unwrap(v) { return v == null || v.isNil() ? null : ObjC.deepUnwrap(v); }
function domain(d) { return d === 'global' ? $.kCFPreferencesAnyApplication : $(d); }
function host(h) { return h ? $.kCFPreferencesCurrentHost : $.kCFPreferencesAnyHost; }
function nsDomain(d) { return d === 'global' ? $.NSGlobalDomain : $(d); }
// CFPreferencesCopyValue/SetValue/Synchronize are plain C functions; on this macOS build their
// CFTypeRef return values never bridge back to a usable JS object (always an opaque, un-unwrappable
// Ref), even for simple calls like CFPreferencesCopyKeyList, and complex values (arrays of dicts)
// silently fail to persist even when passed as arguments. NSUserDefaults is a real Objective-C
// class and bridges correctly, so "any host" preference IO goes through its persistent-domain API.
// Per-host domains (e.g. keyboard modifier mapping) have no NSUserDefaults equivalent, so those
// shell out to the `defaults` CLI via NSTask instead -- see readHostDomain/writeHostKey below.
function runTask(path, args) {
    var task = $.NSTask.alloc.init;
    task.executableURL = $.NSURL.fileURLWithPath(path);
    task.arguments = $(args);
    var outPipe = $.NSPipe.alloc.init, errPipe = $.NSPipe.alloc.init;
    task.standardOutput = outPipe;
    task.standardError = errPipe;
    if (!task.launchAndReturnError(Ref())) throw new Error('Could not run ' + path);
    var data = outPipe.fileHandleForReading.readDataToEndOfFile;
    task.waitUntilExit;
    if (task.terminationStatus !== 0) {
        var errData = errPipe.fileHandleForReading.readDataToEndOfFile;
        var errStr = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(errData, $.NSUTF8StringEncoding)) || '';
        throw new Error(path + ' ' + args.join(' ') + ' failed: ' + errStr.trim());
    }
    return data;
}
function readHostDomain(domain) {
    var data = runTask('/usr/bin/defaults', ['-currentHost', 'export', domain, '-']);
    var plist = $.NSPropertyListSerialization.propertyListWithDataOptionsFormatError(data, 0, null, Ref());
    return plist.isNil() ? {} : ObjC.deepUnwrap(plist);
}
// Serializes to the legacy NeXTSTEP plist text `defaults write` accepts as a single argument.
// Only numbers, strings, arrays and flat dictionaries are needed here (modifier-mapping entries).
function nextStep(v) {
    if (Array.isArray(v)) return '(' + v.map(nextStep).join(',') + ')';
    if (v !== null && typeof v === 'object') return '{' + Object.keys(v).map(function(k) { return k + '=' + nextStep(v[k]) + ';'; }).join('') + '}';
    if (typeof v === 'number') return String(v);
    return '"' + String(v).replace(/(["\\])/g, '\\$1') + '"';
}
function writeHostKey(domain, key, v) {
    if (v === null) { runTask('/usr/bin/defaults', ['-currentHost', 'delete', domain, key]); return; }
    runTask('/usr/bin/defaults', ['-currentHost', 'write', domain, key, nextStep(v)]);
}
function read(d, k, h) {
    if (h) {
        var hostDict = readHostDomain(d === 'global' ? 'NSGlobalDomain' : d);
        return Object.prototype.hasOwnProperty.call(hostDict, k) ? hostDict[k] : null;
    }
    var dom = $.NSUserDefaults.standardUserDefaults.persistentDomainForName(nsDomain(d));
    if (dom.isNil()) return null;
    var dict = ObjC.deepUnwrap(dom);
    return Object.prototype.hasOwnProperty.call(dict, k) ? dict[k] : null;
}
function write(d, k, h, v) {
    if (h) {
        writeHostKey(d === 'global' ? 'NSGlobalDomain' : d, k, v);
        if (!same(read(d, k, h), v)) throw new Error('Readback failed: ' + d + '/' + k);
        return;
    }
    var ud = $.NSUserDefaults.standardUserDefaults;
    var nd = nsDomain(d);
    var current = ud.persistentDomainForName(nd);
    var mutable = current.isNil() ? $.NSMutableDictionary.alloc.init : $.NSMutableDictionary.dictionaryWithDictionary(current);
    if (v === null) mutable.removeObjectForKey($(k));
    else mutable.setValueForKey($(v), $(k));
    ud.setPersistentDomainForName(mutable, nd);
    if (!ud.synchronize) throw new Error('Could not save ' + d + '/' + k);
    if (!same(read(d, k, h), v)) throw new Error('Readback failed: ' + d + '/' + k);
}
function planFile(fileEntries, fm, path, after) {
    var exists = fm.fileExistsAtPath($(path));
    var before = exists ? ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, null)) : null;
    if (before === after) return;
    fileEntries.push({path: path, before: before, after: after});
    console.log('Change: file ' + path);
}
function restoreFiles(fm, files, dry) {
    var remaining = [];
    files.slice().reverse().forEach(function(f) {
        var exists = fm.fileExistsAtPath($(f.path));
        var current = exists ? ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(f.path), $.NSUTF8StringEncoding, null)) : null;
        if (current === f.before) return;
        if (current !== f.after) {
            console.log('SKIPPED (changed since setup): file ' + f.path);
            remaining.unshift(f);
            return;
        }
        if (!dry) {
            if (f.before === null) fm.removeItemAtPathError($(f.path), null);
            else $(f.before).writeToFileAtomicallyEncodingError($(f.path), true, $.NSUTF8StringEncoding, null);
        }
        console.log((dry ? 'Would restore: file ' : 'Restored: file ') + f.path);
    });
    return remaining;
}
function saveJSON(path, value) {
    var error = Ref();
    if (!$(JSON.stringify(value, null, 2)).writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, error))
        throw new Error('Could not write backup: ' + path);
}
function loadJSON(path) {
    var s = $.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, null);
    if (s.isNil()) throw new Error('Cannot read ' + path);
    return JSON.parse(ObjC.unwrap(s));
}
function restore(entries, dry) {
    var remaining = [];
    entries.slice().reverse().forEach(function(e) {
        var current = read(e.domain, e.key, e.host);
        if (same(current, e.before)) return;
        if (!same(current, e.after)) {
            console.log('SKIPPED (changed since setup): ' + e.domain + '/' + e.key);
            remaining.unshift(e);
            return;
        }
        if (!dry) write(e.domain, e.key, e.host, e.before);
        console.log((dry ? 'Would restore: ' : 'Restored: ') + e.domain + '/' + e.key);
    });
    return remaining;
}
function patchMap(original, controlMask) {
    controlMask = controlMask || 0x40000;
    var shifted = controlMask | 0x20000;
    // Arrow/function keys always carry the legacy NSNumericPadKeyMask bit (0x200000) in iTerm2's
    // serialized flags, unlike letter keys such as C/V above.
    var arrowMods = controlMask | 0x200000;
    var result = clone(original || {});
    // Handle both old character-only and newer physical-key serializations.
    Object.keys(result).forEach(function(key) {
        var m = /^0x([0-9a-f]+)-0x([0-9a-f]+)(?:-0x([0-9a-f]+))?/i.exec(key);
        if (!m) return;
        var ch = parseInt(m[1], 16), flags = parseInt(m[2], 16);
        var keycode = m[3] === undefined ? -1 : parseInt(m[3], 16);
        var isCV = [0x63, 0x43, 0x76, 0x56].indexOf(ch) >= 0 || [8, 9].indexOf(keycode) >= 0;
        if (isCV && [controlMask, shifted].indexOf(flags) >= 0) delete result[key];
    });
    // Select Menu Item preserves iTerm's normal paste/bracketed-paste behavior.
    ['0x63-0x' + shifted.toString(16) + '-0x8', '0x43-0x' + shifted.toString(16) + '-0x8'].forEach(function(k) {
        result[k] = {Action: 25, Text: 'Copy'};
    });
    ['0x76-0x' + shifted.toString(16) + '-0x9', '0x56-0x' + shifted.toString(16) + '-0x9'].forEach(function(k) {
        result[k] = {Action: 25, Text: 'Paste'};
    });
    result['0x63-0x' + controlMask.toString(16) + '-0x8'] = {Action: 11, Text: '0x03'};
    result['0x76-0x' + controlMask.toString(16) + '-0x9'] = {Action: 11, Text: '0x16'};
    // Replace the default Left/Right (Select Previous/Next Session) with word-left/word-right,
    // sent as the standard readline/zsh Emacs sequences Esc+b / Esc+f. This overrides iTerm2's
    // built-in session/pane switching on these keys; Shift+Left/Right (move tab) is untouched.
    result['0xf702-' + '0x' + arrowMods.toString(16)] = {Action: 10, Text: 'b'};
    result['0xf703-' + '0x' + arrowMods.toString(16)] = {Action: 10, Text: 'f'};
    return result;
}

function run(args) {
    var apply = args.indexOf('--apply') >= 0;
    var undo = args.indexOf('--undo') >= 0;
    var remap = args.indexOf('--linux-modifiers') >= 0;
    var keepFnCommand = args.indexOf('--fn-command') >= 0;
    var known = ['--apply', '--undo', '--linux-modifiers', '--fn-command', '--help'];
    if (args.some(function(a) { return known.indexOf(a) < 0; }) || (apply && undo) || (remap && keepFnCommand))
        throw new Error('Use --help for valid arguments.');
    if (args.indexOf('--help') >= 0) return [
        'bash setup.command                         Preview only',
        'bash setup.command --apply                 Apply logical shortcuts',
        'bash setup.command --apply --fn-command    Keep existing Fn=Command; physical Control acts as Linux Super',
        'bash setup.command --apply --linux-modifiers  Also map Fn to Control and left Control to Command',
        'bash setup.command --undo                  Restore saved preferences',
        'Requires macOS 15+, English window menus, and iTerm2 closed for apply/undo.',
        'Super means Command by default, Control with --fn-command. Moving a window to Space 1-9 is NOT implemented.'
    ].join('\n');
    var fm = $.NSFileManager.defaultManager;
    var stateDir = ObjC.unwrap($.NSHomeDirectory()) + '/Library/Application Support/LocalLinuxShortcuts';
    var statePath = stateDir + '/backup.json';
    var iterm = 'com.googlecode.iterm2';
    var running = $.NSRunningApplication.runningApplicationsWithBundleIdentifier($(iterm)).count > 0;
    if ((apply || undo) && running)
        throw new Error('Quit iTerm2 normally first, then run this script in Apple Terminal. No sessions have been closed by this script.');
    if (undo) {
        var saved = loadJSON(statePath);
        if (saved.version !== 1) throw new Error('Unknown backup format.');
        saved.entries = restore(saved.entries, false);
        saved.files = restoreFiles(fm, saved.files || [], false);
        saveJSON(statePath, saved);
        if (!saved.entries.length && !saved.files.length) fm.removeItemAtPathError($(statePath), null);
        return 'Restore finished. Log out and back in. Any skipped preferences remain in backup.json.';
    }
    var version = ObjC.unwrap($.NSProcessInfo.processInfo.operatingSystemVersionString);
    console.log('OS: ' + version);
    var major = $.NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    if (major < 15) throw new Error('The native window tiling used here requires macOS 15 or newer.');
    var langs = read('global', 'AppleLanguages', false) || ObjC.deepUnwrap($.NSLocale.preferredLanguages);
    console.log('Languages: ' + JSON.stringify(langs));
    if (!langs.length || !/^en(?:-|$)/.test(langs[0]))
        throw new Error('This version targets English menu titles. Send the OS version and menu language so the titles can be adapted; nothing was changed.');
    if (read(iterm, 'LoadPrefsFromCustomFolder', false))
        throw new Error('iTerm2 loads custom/shared preferences. This script will not edit that source; nothing was changed.');

    var entries = [];
    var fileEntries = [];
    function plan(d, k, after, h) {
        var before = read(d, k, !!h);
        if (same(before, after)) return;
        if ($.CFPreferencesAppValueIsForced($(k), domain(d)))
            throw new Error('Preference is managed by your organization: ' + d + '/' + k);
        entries.push({domain:d, key:k, host:!!h, before:before, after:clone(after)});
        console.log('Change: ' + d + '/' + k);
    }

    var equivalents = read('global', 'NSUserKeyEquivalents', false) || {};
    [['Left', '\uf702'], ['Right', '\uf703'], ['Fill', '\uf700'], ['Return to Previous Size', '\uf701']].forEach(function(p) {
        // Cocoa stores a full menu path with ESC separators.
        equivalents['\u001bWindow\u001bMove & Resize\u001b' + p[0]] = (keepFnCommand ? '^' : '@') + p[1];
    });
    plan('global', 'NSUserKeyEquivalents', equivalents);
    var hotkeys = read('com.apple.symbolichotkeys', 'AppleSymbolicHotKeys', false) || {};
    function shortcut(id, keycode, flags) {
        hotkeys[id] = {enabled:true, value:{type:'standard', parameters:[65535, keycode, flags]}};
    }
    shortcut('79', 123, 0x140000); // Control + Command + Left
    shortcut('81', 124, 0x140000); // Control + Command + Right
    // Keep the system's paired Shift variants consistent with the new modifiers.
    shortcut('80', 123, 0x160000);
    shortcut('82', 124, 0x160000);
    if (keepFnCommand) {
        // Release the standard Mission Control/App Expose bindings for tiling.
        [['32', 126], ['33', 125]].forEach(function(pair) {
            var item = hotkeys[pair[0]];
            var params = item && item.value && item.value.parameters;
            if (!item || (params && params[1] === pair[1] && params[2] === 0x40000)) {
                hotkeys[pair[0]] = item || {};
                hotkeys[pair[0]].enabled = false;
            }
        });
    }
    plan('com.apple.symbolichotkeys', 'AppleSymbolicHotKeys', hotkeys);
    plan('com.apple.dock', 'mru-spaces', false);

    var appURL = $.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier($(iterm));
    if (appURL.isNil()) throw new Error('iTerm2 was not found. Nothing was changed.');
    var globalMap = read(iterm, 'GlobalKeyMap', false);
    if (globalMap === null) {
        var bundle = $.NSBundle.bundleWithURL(appURL);
        var resource = bundle.pathForResourceOfType($('DefaultGlobalKeyMap'), $('plist'));
        if (resource.isNil()) throw new Error('Cannot find iTerm2 default bindings; refusing to replace them with an incomplete map.');
        globalMap = unwrap($.NSDictionary.dictionaryWithContentsOfFile(resource));
        if (globalMap === null) throw new Error('Cannot read iTerm2 default bindings.');
    }
    var terminalControlMask = keepFnCommand ? 0x100000 : 0x40000;
    plan(iterm, 'GlobalKeyMap', patchMap(globalMap, terminalControlMask));
    var profiles = read(iterm, 'New Bookmarks', false);
    if (Array.isArray(profiles)) {
        profiles.forEach(function(p) {
            if (p['Dynamic Profile Parent Name'] || p['Dynamic Profile Filename'])
                throw new Error('Dynamic iTerm profiles need separate review; nothing was changed.');
            p['Keyboard Map'] = patchMap(p['Keyboard Map'], terminalControlMask);
        });
        plan(iterm, 'New Bookmarks', profiles);
    }
    // Also update menu equivalents in case an existing Ctrl+C override is present.
    var itermMenus = read(iterm, 'NSUserKeyEquivalents', false) || {};
    itermMenus.Copy = (keepFnCommand ? '@' : '^') + '$c';
    itermMenus.Paste = (keepFnCommand ? '@' : '^') + '$v';
    plan(iterm, 'NSUserKeyEquivalents', itermMenus);

    // Word-jump in Cocoa text views (TextEdit, Mail, Outlook, Xcode, Chrome's address bar, etc.)
    // -- native NSResponder mechanism, no app to install. Bare Control+Left/Right is freed from
    // Mission Control space-switching above (hotkeys 79/81 moved to Control+Command) in every
    // mode, so binding it here is safe whether or not --fn-command/--linux-modifiers is used.
    // Command+Left/Right is only repurposed under --fn-command, where physical Command (Fn) is
    // not needed for Super and would otherwise just move to line start/end.
    var keyBindingsPath = ObjC.unwrap($.NSHomeDirectory()) + '/Library/KeyBindings/DefaultKeyBinding.dict';
    var keyBindingsLines = ['{'];
    if (keepFnCommand) {
        keyBindingsLines.push('    "@\\UF702" = "moveWordLeft:";');
        keyBindingsLines.push('    "@\\UF703" = "moveWordRight:";');
        keyBindingsLines.push('    "@$\\UF702" = "moveWordLeftAndModifySelection:";');
        keyBindingsLines.push('    "@$\\UF703" = "moveWordRightAndModifySelection:";');
    }
    keyBindingsLines.push('    "^\\UF702" = "moveWordLeft:";');
    keyBindingsLines.push('    "^\\UF703" = "moveWordRight:";');
    keyBindingsLines.push('    "^$\\UF702" = "moveWordLeftAndModifySelection:";');
    keyBindingsLines.push('    "^$\\UF703" = "moveWordRightAndModifySelection:";');
    keyBindingsLines.push('}');
    keyBindingsLines.push('');
    planFile(fileEntries, fm, keyBindingsPath, keyBindingsLines.join('\n'));

    // VS Code: Control+Left/Right is a logical modifier VS Code reads directly, independent of
    // the Fn/Control scheme above, so this applies the same way in every mode. Only touches the
    // four key chords below; any other existing bindings in the file are preserved as-is.
    var vscodeAppURL = $.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier($('com.microsoft.VSCode'));
    if (!vscodeAppURL.isNil()) {
        var vscodeKeysPath = ObjC.unwrap($.NSHomeDirectory()) + '/Library/Application Support/Code/User/keybindings.json';
        var vscodeExists = fm.fileExistsAtPath($(vscodeKeysPath));
        var vscodeBefore = vscodeExists ? ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(vscodeKeysPath), $.NSUTF8StringEncoding, null)) : null;
        var vscodeOurs = [
            {key: 'ctrl+left', command: 'cursorWordLeft', when: 'textInputFocus'},
            {key: 'ctrl+right', command: 'cursorWordRight', when: 'textInputFocus'},
            {key: 'ctrl+shift+left', command: 'cursorWordLeftSelect', when: 'textInputFocus'},
            {key: 'ctrl+shift+right', command: 'cursorWordRightSelect', when: 'textInputFocus'}
        ];
        var vscodeOurKeys = vscodeOurs.map(function(b) { return b.key; });
        var vscodeArr;
        if (vscodeBefore === null || vscodeBefore.trim() === '') {
            vscodeArr = [];
        } else {
            try {
                vscodeArr = JSON.parse(vscodeBefore);
                if (!Array.isArray(vscodeArr)) throw new Error('not an array');
            } catch (e) {
                throw new Error('VS Code keybindings.json has content this script cannot safely merge (comments or invalid JSON). Add the Ctrl+Left/Right word-jump bindings by hand; nothing else was changed.');
            }
        }
        vscodeArr = vscodeArr.filter(function(b) { return !b || vscodeOurKeys.indexOf(b.key) < 0; });
        var vscodeAfter = JSON.stringify(vscodeArr.concat(vscodeOurs), null, 4) + '\n';
        planFile(fileEntries, fm, vscodeKeysPath, vscodeAfter);
    }

    if (remap) {
        var FN = 0xff00000003, CTRL = 0x7000000e0, CMD = 0x7000000e3;
        var hostDump = readHostDomain('NSGlobalDomain');
        var existingKeys = Object.keys(hostDump).filter(function(k) {
            return k.indexOf('com.apple.keyboard.modifiermapping.') === 0;
        });
        var targetKey, mappings;
        if (existingKeys.length > 1) {
            throw new Error('Multiple existing keyboard modifier mappings found. Use Modifier Keys in System Settings instead; nothing was changed.');
        } else if (existingKeys.length === 1) {
            // Extend whatever mapping is already there (e.g. set up by hand in System Settings).
            targetKey = existingKeys[0];
            mappings = (hostDump[targetKey] || []).filter(function(p) {
                return [FN, CTRL].indexOf(p.HIDKeyboardModifierMappingSrc) < 0;
            });
        } else {
            // No existing mapping (fresh Mac): Apple Silicon's built-in keyboard always reports
            // VendorID=0/ProductID=0 and macOS normalizes its LocationID component to 0 in this
            // preference, so "0-0-0" reliably identifies the built-in keyboard on any such Mac.
            targetKey = 'com.apple.keyboard.modifiermapping.0-0-0';
            mappings = [];
        }
        mappings.push({HIDKeyboardModifierMappingSrc:FN, HIDKeyboardModifierMappingDst:CTRL});
        mappings.push({HIDKeyboardModifierMappingSrc:CTRL, HIDKeyboardModifierMappingDst:CMD});
        plan('global', targetKey, mappings, true);
    }
    console.log(keepFnCommand ? 'Keep your existing Fn=Command mapping. Physical Fn acts as Linux Ctrl; physical Control acts as Linux Super.' : 'Super=Command; Ctrl=Control.');
    console.log('Window movement to numbered Spaces is not configured.');
    if (!apply) return 'Preview only. Add --apply to save the selected configuration.';
    if (!entries.length && !fileEntries.length) return 'Already configured. No changes required.';
    if (fm.fileExistsAtPath($(statePath)))
        throw new Error('A previous backup exists. Undo the earlier setup before applying a different configuration.');
    if (!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(stateDir), true, $({NSFilePosixPermissions:448}), null))
        throw new Error('Cannot create backup directory.');
    saveJSON(statePath, {version:1, entries:entries, files:fileEntries});
    try {
        entries.forEach(function(e) { write(e.domain, e.key, e.host, e.after); });
        fileEntries.forEach(function(f) {
            var dir = f.path.substring(0, f.path.lastIndexOf('/'));
            fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError($(dir), true, $({NSFilePosixPermissions:448}), null);
            if (!$(f.after).writeToFileAtomicallyEncodingError($(f.path), true, $.NSUTF8StringEncoding, null))
                throw new Error('Could not write file: ' + f.path);
        });
    } catch (e) {
        console.log('Apply failed; restoring preferences already changed.');
        var remaining = restore(entries, false);
        var remainingFiles = restoreFiles(fm, fileEntries, false);
        saveJSON(statePath, {version:1, entries:remaining, files:remainingFiles});
        if (!remaining.length && !remainingFiles.length) fm.removeItemAtPathError($(statePath), null);
        throw e;
    }
    return 'Saved. Backup: ' + statePath + '\nLog out and back in to load the settings. No apps were forcibly closed.';
}
JXA
