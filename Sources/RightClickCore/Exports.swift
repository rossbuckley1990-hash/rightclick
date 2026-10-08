@_exported import RightClickProtocol
@_exported import RightClickProviders
#if os(macOS)
@_exported import RightClickMacOS
#endif
#if os(Linux)
@_exported import RightClickLinux
#endif

#if !os(macOS)
/// Portable descriptor acquisition compatibility; does not advertise native Bonjour.
public typealias BonjourOpenAPISource = OpenAPIServiceDescriptorSource
#endif
