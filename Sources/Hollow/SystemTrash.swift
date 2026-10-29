// SPDX-License-Identifier: GPL-3.0-or-later

import DiskApp
import Foundation

/// The app's one way to move a file to the Trash. Only `Trasher` calls it, with items the user checked in the review
/// sheet. A symlink is moved as the link; its target is not touched. Nothing here empties the Trash.
struct SystemTrash: TrashBackend {
    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
