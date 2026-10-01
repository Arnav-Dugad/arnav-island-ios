The first version of Arnav Island for iPhone: the Android app, rebuilt natively in Swift and SwiftUI, with the iPhone's own extras.

## Install

Download `ArnavIsland.ipa` below and install it with **AltStore** or **SideStore** using a free Apple ID. With a free Apple ID the app is refreshed every 7 days, and AltStore does that by itself. The [README](https://github.com/Arnav-Dugad/arnav-island-ios#put-it-on-an-iphone-for-free) has the step-by-step guide.

## What's in it

- **Remote:**
  - What plays on your PC, with its cover; the cover leans as you tilt the iPhone and flips over to show the lyrics word by word.
  - A scrubber that ticks at each lyric line.
  - The volume on a dial.
  - The clipboard both ways; lock your PC; Find my PC; open a link on it.
- **Island:**
  - The PC's numbers live: Swift Charts you can scrub, a bar for each core, and the card warms when the PC works hard.
  - Its battery and its last day.
  - Wi-Fi, Bluetooth, airplane mode, dark mode, brightness, mic and mute.
  - The focus clock, which also runs in your Dynamic Island.
  - The command bar, power, where its sound plays, its pages, and every island setting.
- **Send:**
  - Photos and videos at full quality (HEIC as JPEG if you like), files and whole folders.
  - Documents scanned into PDFs, the clipboard (text or a picture), live transfers and your history.
  - Share › Arnav Island from any app: AirDrop-style bubbles, with a page from Safari opening on your PC where you had scrolled to.
- **Shelf:** take anything from your PC's Shelf with a tap.
- **The PC's screen, here:**
  - Hardware-decoded; touch it like a touchscreen, pinch to zoom, and use Picture in Picture.
  - Or show this iPhone's camera in a window on your PC.
- **Trackpad and keyboard**, including a keyboard paired to the iPhone.
- **Handing over:**
  - Music continues here from the same second, with Lock Screen controls, AirPods and AirPlay; hand it back with one tap.
  - Pages hand over both ways.
- **Find this iPhone:** your PC rings it, even on silent and at full volume, with the flashlight blinking.

## iPhone only

- The app's island grows out of the iPhone's own Dynamic Island.
- Live Activities: music with controls, transfers, and the focus clock.
- Widgets on the Home Screen and Lock Screen.
- Control Center controls (play or pause, lock, find).
- Siri and Shortcuts: "Lock my PC with Arnav Island", "Find my PC", "How's my PC". The Action button too.
- A Face ID lock; the app switcher shows the app frosted; the key is kept in the Secure Enclave.
- Liquid Glass on iOS 26, the light following your tilt, weather on the glass, and haptics throughout.

## Tested

- The protocol matches the island byte for byte, in known-answer tests from the verified web and Android implementations.
- It passed a live run against the island's own engine over the internet:
  - pairing, the remote, lyrics and both clipboards
  - pages both ways, settings, controls and audio outputs
  - sending with a preview, the Shelf and receiving
  - music handoff, ring, the trackpad and the PC's screen
- Every screen was checked in the simulator.
