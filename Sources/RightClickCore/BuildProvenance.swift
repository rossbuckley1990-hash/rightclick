/// Build facts are compiled into the executable. Environment variables and
/// mutable sidecars cannot promote development bytes to Stable or Edge.
public enum RightClickBuildProvenance {
#if RIGHTCLICK_BUILD_METADATA
    public static let channel = RightClickCompiledBuildMetadata.channel
    public static let gitCommit: String? = RightClickCompiledBuildMetadata.gitCommit
    public static let sourceRepository: String? = RightClickCompiledBuildMetadata.sourceRepository
    public static let sourceDirty: Bool? = RightClickCompiledBuildMetadata.sourceDirty
#else
    public static let channel = "unverified"
    public static let gitCommit: String? = nil
    public static let sourceRepository: String? = nil
    public static let sourceDirty: Bool? = nil
#endif
}
