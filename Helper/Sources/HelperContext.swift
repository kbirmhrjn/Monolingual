//
//  HelperContext.swift
//  Monolingual
//
//  Created by Ingmar Stein on 10.04.15.
//
//

import Foundation
import os

final class HelperContext: NSObject, FileManagerDelegate {

	var request: HelperRequest
	var remoteProgress: ProgressProtocol?
	var progress: Progress?
	private var fileBlacklist = Set<URL>()
	let fileManager = FileManager()
	let isRootless: Bool

	init(_ request: HelperRequest, rootless: Bool) {
		self.request = request
		self.isRootless = rootless

		super.init()

		fileManager.delegate = self
	}

	func isExcluded(_ url: URL) -> Bool {
		if let excludes = request.excludes {
			let path = url.path
			for exclude in excludes {
				if path.hasPrefix(exclude) {
					return true
				}
			}
		}
		return false
	}

	func excludeDirectory(_ url: URL) {
		if request.excludes != nil {
			request.excludes?.append(url.path)
		} else {
			request.excludes = [url.path]
		}
	}

	func isDirectoryBlacklisted(_ path: URL) -> Bool {
		if let bundle = Bundle(url: path), let bundleIdentifier = bundle.bundleIdentifier, let bundleBlacklist = request.bundleBlacklist {
			return bundleBlacklist.contains(bundleIdentifier)
		}
		return false
	}

	func isFileBlacklisted(_ url: URL) -> Bool {
		return fileBlacklist.contains(url)
	}

	private func addFileDictionaryToBlacklist(_ files: [String: AnyObject], baseURL: URL) {
		for (key, value) in files {
			if let valueDict = value as? [String: AnyObject], let optional = valueDict["optional"] as? Bool, optional {
				continue
			}
			fileBlacklist.insert(baseURL.appendingPathComponent(key))
		}
	}

	func addCodeResourcesToBlacklist(_ url: URL) {
		var codeRef: SecStaticCode?
		let result = SecStaticCodeCreateWithPath(url as CFURL, [], &codeRef)
		if result == errSecSuccess, let code = codeRef {
			var codeInfoRef: CFDictionary?
			// warning: this relies on kSecCSInternalInformation
			let secCSInternalInformation = SecCSFlags(rawValue: 1)
			let result2 = SecCodeCopySigningInformation(code, secCSInternalInformation, &codeInfoRef)
			if result2 == errSecSuccess, let codeInfo = codeInfoRef as? [String: AnyObject] {
				if let resDir = codeInfo["ResourceDirectory"] as? [String: AnyObject] {
					let baseURL: URL

					let contentsDirectory = url.appendingPathComponent("Contents", isDirectory: true)
					if fileManager.fileExists(atPath: contentsDirectory.path) {
						baseURL = contentsDirectory
					} else {
						baseURL = url
					}
					if let files = resDir["files"] as? [String: AnyObject] {
						addFileDictionaryToBlacklist(files, baseURL: baseURL)
					}

					// Version 2 Code Signature (introduced in Mavericks)
					// https://developer.apple.com/library/mac/technotes/tn2206
					if let files = resDir["files2"] as? [String: AnyObject] {
						addFileDictionaryToBlacklist(files, baseURL: baseURL)
					}
				}
			}
		}
	}

	private func appNameForURL(_ url: URL) -> String? {
		let pathComponents = url.pathComponents
		for (i, pathComponent) in pathComponents.enumerated() {
			if (pathComponent as NSString).pathExtension == "app" {
				if let bundleURL = NSURL.fileURL(withPathComponents: Array(pathComponents[0...i])) {
					if let bundle = Bundle(url: bundleURL) {
						var displayName: String?
						if let localization = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first,
							let infoPlistStringsURL = bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: localization),
							let strings = NSDictionary(contentsOf: infoPlistStringsURL) as? [String: String] {
							displayName = strings["CFBundleDisplayName"]
						}
						if displayName == nil {
							// seems not to be localized?!?
							displayName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
						}
						if let displayName = displayName {
							return displayName
						}
					}
				}
				return pathComponent.substring(to: pathComponent.index(pathComponent.endIndex, offsetBy: -4))
			}
		}
		return nil
	}

	func reportProgress(url: URL, size: Int) {
		let appName = appNameForURL(url)
		if let progress = progress {
			let count = progress.userInfo[.fileCompletedCountKey] as? Int ?? 0
			progress.setUserInfoObject(count + 1, forKey: .fileCompletedCountKey)
			progress.setUserInfoObject(url, forKey: .fileURLKey)
			progress.setUserInfoObject(size, forKey: ProgressUserInfoKey("sizeDifference"))
			if let appName = appName {
				progress.setUserInfoObject(appName, forKey: ProgressUserInfoKey("appName"))
			}
			progress.completedUnitCount += size
		}
		if let progress = remoteProgress {
			progress.processed(file: url.path, size: size, appName: appName)
		}
	}

	func remove(_ url: URL) {
		var error: Error? = nil
		if request.trash {
			if request.dryRun {
				return
			}

			var dstURL: NSURL? = nil

			// trashItemAtURL does not call any delegate methods (radar 20481813)

			// check if any file in below url has been blacklisted
			if let dirEnumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: nil) {
				for entry in dirEnumerator {
					let theURL = entry as! URL
					if isFileBlacklisted(theURL) {
						return
					}
				}
			}

			// try to move the file to the user's trash
			var success = false
			seteuid(request.uid)
			do {
				try fileManager.trashItem(at: url, resultingItemURL: &dstURL)
				success = true
			} catch let error1 {
				error = error1
				success = false
			}
			seteuid(0)
			if !success {
				do {
					// move the file to root's trash
					try self.fileManager.trashItem(at: url, resultingItemURL: &dstURL)
					success = true
				} catch let error1 {
					error = error1
					success = false
				}
			}

			if success {
				if let dirEnumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [URLResourceKey.totalFileAllocatedSizeKey, URLResourceKey.fileAllocatedSizeKey], options: [], errorHandler: nil) {
					for entry in dirEnumerator {
						let theURL = entry as! URL
						do {
							let resourceValues = try theURL.resourceValues(forKeys: [URLResourceKey.totalFileAllocatedSizeKey, URLResourceKey.fileAllocatedSizeKey])
							if let size = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize {
								reportProgress(url: theURL, size: size)
							}
						} catch _ {
						}
					}
				}
			} else if let error = error {
				os_log("Error trashing '%@': %@", type: .error, url.path, error.localizedDescription)
			}
		} else {
			do {
				try self.fileManager.removeItem(at: url)
			} catch let error1 {
				error = error1
				if let error = error as? NSError {
					if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlyingError.domain == NSPOSIXErrorDomain && underlyingError.code == Int(ENOTEMPTY) {
						// ignore non-empty directories (they might contain blacklisted files and cannot be removed)
					} else {
						os_log("Error removing '%@': %@", type: .error, url.path, error)
					}
				}
			}
		}
	}

	private func fileManager(_ fileManager: FileManager, shouldProcessItemAtURL url: URL) -> Bool {
		if request.dryRun || isFileBlacklisted(url) || (isRootless && url.isProtected) {
			return false
		}

		// TODO: it is wrong to report process here, deletion might fail
		do {
			let resourceValues = try url.resourceValues(forKeys: [URLResourceKey.totalFileAllocatedSizeKey, URLResourceKey.fileAllocatedSizeKey])
			if let size = resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize {
				reportProgress(url: url, size: size)
			}
		} catch _ {
		}
		return true
	}

	// MARK: - NSFileManagerDelegate

	func fileManager(_ fileManager: FileManager, shouldRemoveItemAt url: URL) -> Bool {
		return self.fileManager(fileManager, shouldProcessItemAtURL: url)
	}

	func fileManager(_ fileManager: FileManager, shouldProceedAfterError error: Error, removingItemAt url: URL) -> Bool {
		os_log("Error removing '%@': %@", type: .error, url.path, error.localizedDescription)

		return true
	}

}
