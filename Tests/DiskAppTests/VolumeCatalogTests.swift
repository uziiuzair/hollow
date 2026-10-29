// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
import Foundation
@testable import DiskApp

@Test func catalogFilter() {
    #expect(VolumeCatalog.isDrive(isInternal: false, isLocal: true, isBrowsable: true, isRootFileSystem: false, isReadOnly: false))
    #expect(!VolumeCatalog.isDrive(isInternal: false, isLocal: true, isBrowsable: true, isRootFileSystem: false, isReadOnly: true))
    #expect(!VolumeCatalog.isDrive(isInternal: false, isLocal: false, isBrowsable: true, isRootFileSystem: false, isReadOnly: false))
    #expect(!VolumeCatalog.isDrive(isInternal: true, isLocal: true, isBrowsable: true, isRootFileSystem: false, isReadOnly: false))
}

@Test func currentAlwaysStartsWithInternalData() {
    #expect(VolumeCatalog.current().first?.isInternalData == true)
}
