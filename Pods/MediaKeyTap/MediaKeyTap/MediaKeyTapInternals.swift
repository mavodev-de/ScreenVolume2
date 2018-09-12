//
//  MediaKeyTapInternals.swift
//  Castle
//
//  A wrapper around the C APIs required for a CGEventTap
//
//  Created by Nicholas Hurden on 18/02/2016.
//  Copyright © 2016 Nicholas Hurden. All rights reserved.
//

import Cocoa
import CoreGraphics

enum EventTapError: Error {
    case eventTapCreationFailure
    case runLoopSourceCreationFailure
}

extension EventTapError: CustomStringConvertible {
    var description: String {
        switch self {
        case .eventTapCreationFailure: return "Event tap creation failed: is your application sandboxed?"
        case .runLoopSourceCreationFailure: return "Runloop source creation failed"
        }
    }
}

protocol MediaKeyTapInternalsDelegate {
	var keysToWatch: [MediaKey] { get set }
	var observeBuiltIn: Bool { get set }
    func updateInterceptMediaKeys(_ intercept: Bool)
	func handle(keyEvent: KeyEvent, isFunctionKey: Bool)
    func isInterceptingMediaKeys() -> Bool
}

class MediaKeyTapInternals {
    typealias EventTapCallback = @convention(block) (CGEventType, CGEvent) -> CGEvent?

    var delegate: MediaKeyTapInternalsDelegate?
    var keyEventPort: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var callback: EventTapCallback?
    var runLoopQueue: DispatchQueue?
    var runLoop: CFRunLoop?

    deinit {
        stopWatchingMediaKeys()
    }

    /**
        Enable/Disable the underlying tap
    */
    func enableTap(_ onOff: Bool) {
        if let port = self.keyEventPort, let runLoop = self.runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes as CFTypeRef!) {
                CGEvent.tapEnable(tap: port, enable: onOff)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    /**
        Restart the tap, placing it in front of existing taps
    */
    func restartTap() throws {
        stopWatchingMediaKeys()
        try startWatchingMediaKeys(restart: true)
    }

    func startWatchingMediaKeys(restart: Bool = false) throws {
        let eventTapCallback: EventTapCallback = { type, event in
            if type == .tapDisabledByTimeout {
                if let port = self.keyEventPort {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
                return event
            } else if type == .tapDisabledByUserInput {
                return event
            }

            return self.handle(event: event, ofType: type)
        }

        try startKeyEventTap(callback: eventTapCallback, restart: restart)
        callback = eventTapCallback
    }

    func stopWatchingMediaKeys() {
        CFRunLoopSourceInvalidate <^> runLoopSource
        CFRunLoopStop <^> runLoop
        CFMachPortInvalidate <^> keyEventPort
    }

    private func handle(event: CGEvent, ofType type: CGEventType) -> CGEvent? {
		if type == .keyDown {
			let keycode: Int64 = event.getIntegerValueField(.keyboardEventKeycode)
			guard let mediaKey = MediaKeyTap.functionKeyCodeToMediaKey(Int32(keycode)) else { return event }
			if delegate?.keysToWatch.contains(mediaKey) ?? false {

				if delegate?.observeBuiltIn ?? true == false {
					if let id = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey.init("NSScreenNumber")] as? CGDirectDisplayID {
						if CGDisplayIsBuiltin(id) != 0 {
							return event
						}
					}
				}

				DispatchQueue.main.async {
					self.delegate?.handle(keyEvent: KeyEvent(keycode: Int32(keycode), keyFlags: 0, keyPressed: true, keyRepeat: false), isFunctionKey: true)
				}

				return nil
			} else {
				return event
			}
		}

        if let nsEvent = NSEvent(cgEvent: event) {
			guard let mediaKey = MediaKeyTap.keycodeToMediaKey(nsEvent.keyEvent.keycode) else { return event }
            guard type.rawValue == UInt32(NX_SYSDEFINED)
                && nsEvent.isMediaKeyEvent
				&& delegate?.keysToWatch.contains(mediaKey) ?? false
                && delegate?.isInterceptingMediaKeys() ?? false
            else { return event }

			if delegate?.observeBuiltIn ?? true == false {
				if let id = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey.init("NSScreenNumber")] as? CGDirectDisplayID {
					if CGDisplayIsBuiltin(id) != 0 {
						return event
					}
				}
			}

            DispatchQueue.main.async {
                self.delegate?.handle(keyEvent: nsEvent.keyEvent, isFunctionKey: false)
            }

            return nil
        }

        return event
    }

    private func startKeyEventTap(callback: EventTapCallback, restart: Bool) throws {
        // On a restart we don't want to interfere with the application watcher
        if !restart {
            delegate?.updateInterceptMediaKeys(true)
        }

        keyEventPort = keyCaptureEventTapPort(callback: callback)
        guard let port = keyEventPort else { throw EventTapError.eventTapCreationFailure }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorSystemDefault, port, 0)
        guard let source = runLoopSource else { throw EventTapError.runLoopSourceCreationFailure }

        let queue = DispatchQueue(label: "MediaKeyTap Runloop", attributes: [])
        self.runLoopQueue = queue

        queue.async {
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(self.runLoop, source, CFRunLoopMode.commonModes)
            CFRunLoopRun()
        }
    }

    private func keyCaptureEventTapPort(callback: EventTapCallback) -> CFMachPort? {
        let cCallback: CGEventTapCallBack = { proxy, type, event, refcon in
            let innerBlock = unsafeBitCast(refcon, to: EventTapCallback.self)
            return innerBlock(type, event).map(Unmanaged.passUnretained)
        }

        let refcon = unsafeBitCast(callback, to: UnsafeMutableRawPointer.self)

        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << NX_KEYDOWN) | CGEventMask(1 << NX_SYSDEFINED),
            callback: cCallback,
            userInfo: refcon)
    }
}
