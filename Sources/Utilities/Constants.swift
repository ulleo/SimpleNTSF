import Foundation

// MARK: - Constants

enum Constants {
    static let appVersion = "1.1.0"
    static let configDirName = ".SimpleNTFS"
    static let configFileName = "ntfs-disks.conf"
    static let mountNTFSPath = "/opt/homebrew/sbin/mount_ntfs"
    static let diskUtilPath = "/usr/sbin/diskutil"
    static let sudoersFilePath = "/etc/sudoers.d/simplentfs"
    
    static let forbiddenMountPrefixes = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/var",
        "/Library", "/private", "/Applications", "/Network"
    ]
}
