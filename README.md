# Compare Folders

A macOS 15 application for comparing the contents of two folders.

- The comparison considers names, item types, sizes, creation and modification dates, permissions, and ownership. This reads only file-system metadata, not files themselves, so it’s nearly instant.
- Optionally compare file contents byte-for-byte. Each matched pair of files is read in full (or at least up to the point where a difference is caught), catching differences that metadata can’t reveal, such as silent corruption, or a bad copy that kept the same size and dates, but this takes orders of magnitude longer to complete.
- Results can be filtered and searched.
- Reveal specific items in the Finder or copy their paths.
- Open multiple windows or tabs for performing concurrent comparisons.

## Installation

Compare Folders is not signed with an Apple Developer ID and is not notarized. To launch it, you can either disable Gatekeeper, remove the quarantine flag manually with the command below (using the appropriate path for your installation, of course), navigate to System Settings > Privacy & Security and click "Open Anyway" after first attempting a launch, or build it yourself with Xcode (open `CompareFolders.xcodeproj` in Xcode and choose Product > Build).

```sh
xattr -dr com.apple.quarantine "/Applications/Compare Folders.app"
```

## System Requirements and Security

- macOS 15.6.0 or later, Apple Silicon only.
- Sandboxed, uses Apple's Hardened Runtime, and is compliant with Swift 6 (Strict Concurrency and Strict Memory Safety); built against Xcode 26.3.
- File access is read-only.

## Support

If you find a bug, please report it here on GitHub and I will try to fix it. If it affects macOS 15, I will try harder. Please be as thorough in your reporting as you can.

You're welcome to request features or changes if you're so-inclined, and I will give such requests due consideration, but just know that this application was built first and foremost for an audience of one and I consider it largely feature-complete at this time.

Compare Folders is available in English only, by design.

## Note

I am not a software engineer; all of the code for this project was written by Anthropic's Claude models. That said, I use all of the applications under this account regularly in my daily life, so while they're not perfect, I'm confident in their efficacy and general reliability.

## License

Compare Folders is free software, licensed under the GNU General Public License, version 3 only (GPL-3.0-only). Copyright © 2026 avenged110. The full license text is in `COPYING`.

## Acknowledgments

Compare Folders is a modernized reimplementation of CompareFolders (https://github.com/swisspol/CompareFolders, Copyright © 2014 Pierre-Olivier Latour, GPL-3.0). It is not affiliated with, endorsed by, or supported by this author.
