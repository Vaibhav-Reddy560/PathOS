import Testing
@testable import PathOS

struct PaletteTests {
    @Test func hexValuesMatchTheBrand() {
        #expect(PathOSPalette.void == 0x090B0D)
        #expect(PathOSPalette.deepSurface == 0x101418)
        #expect(PathOSPalette.elevatedSurface == 0x181E22)
        #expect(PathOSPalette.ice == 0xE8F0ED)
        #expect(PathOSPalette.mist == 0x8E9B98)
        #expect(PathOSPalette.aurora == 0xB8F36B)
        #expect(PathOSPalette.ion == 0x65E6D0)
        #expect(PathOSPalette.amber == 0xFFBF69)
        #expect(PathOSPalette.coral == 0xFF6B5F)
    }

    @Test func rolesKeepTheirMeaning() {
        #expect(SignalRole.you.hex == PathOSPalette.aurora)
        #expect(SignalRole.world.hex == PathOSPalette.ion)
        #expect(SignalRole.attention.hex == PathOSPalette.amber)
        #expect(SignalRole.critical.hex == PathOSPalette.coral)
    }

    @Test func textIsReadableOnEverySurface() {
        let surfaces = [PathOSPalette.void, PathOSPalette.deepSurface, PathOSPalette.elevatedSurface]
        let text = [PathOSPalette.ice, PathOSPalette.mist] + SignalRole.allCases.map(\.hex)
        for surface in surfaces {
            for foreground in text {
                #expect(PathOSPalette.contrastRatio(foreground, surface) >= 4.5)
            }
        }
    }

    @Test func filledButtonsUseVoidText() {
        for fill in SignalRole.allCases.map(\.hex) {
            #expect(PathOSPalette.contrastRatio(PathOSPalette.void, fill) >= 4.5)
        }
        // Why labels on Coral must never be Ice.
        #expect(PathOSPalette.contrastRatio(PathOSPalette.ice, PathOSPalette.coral) < 4.5)
    }

    @Test func contrastRatioMatchesKnownValues() {
        #expect(abs(PathOSPalette.contrastRatio(0xFFFFFF, 0x000000) - 21) < 0.001)
        #expect(abs(PathOSPalette.contrastRatio(0x777777, 0x777777) - 1) < 0.001)
    }
}
