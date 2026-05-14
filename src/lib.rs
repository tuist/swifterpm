pub mod cli;

mod cache;
mod github;
mod manifest;
mod package_info_cache;
mod registry;
mod remote;
mod resolve;
mod resolved;
mod restore;
mod solver;
mod util;

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use pubgrub::Ranges;
    use semver::Version;
    use serde_json::json;

    use crate::{
        manifest::{
            Requirement, parse_manifest_dependencies, parse_manifest_file_system_dependencies,
            parse_required_manifest_dependencies,
        },
        remote::parse_swift_tag_version,
        resolved::{ResolvedPins, cache_test_path, checkout_directory_name},
        solver::{
            PubgrubDependencyProvider, SolverPackage, solve_pubgrub_dependencies,
            version_range_for_requirement,
        },
    };

    #[test]
    fn parses_swiftpm_source_control_dependencies() {
        let manifest = json!({
            "dependencies": [
                {
                    "sourceControl": [
                        {
                            "identity": "alamofire",
                            "location": {
                                "remote": [
                                    { "urlString": "https://github.com/Alamofire/Alamofire" }
                                ]
                            },
                            "requirement": {
                                "range": [
                                    { "lowerBound": "5.0.0", "upperBound": "6.0.0" }
                                ]
                            }
                        }
                    ]
                },
                {
                    "registry": [
                        {
                            "identity": "apple.swift-log",
                            "requirement": {
                                "range": [
                                    { "lowerBound": "1.0.0", "upperBound": "2.0.0" }
                                ]
                            }
                        }
                    ]
                },
                {
                    "sourceControl": [
                        {
                            "identity": "local-package",
                            "location": {
                                "local": [
                                    "/tmp/local-package"
                                ]
                            },
                            "requirement": {
                                "exact": ["1.2.3"]
                            }
                        }
                    ]
                }
            ]
        });

        let dependencies = parse_manifest_dependencies(&manifest).unwrap();
        assert_eq!(dependencies.len(), 3);
        assert_eq!(dependencies[0].identity, "alamofire");
        assert_eq!(
            dependencies[0].location,
            "https://github.com/Alamofire/Alamofire"
        );
        assert!(matches!(
            dependencies[0].requirement,
            Requirement::Range { .. }
        ));
        assert_eq!(dependencies[1].identity, "apple.swift-log");
        assert_eq!(dependencies[1].location, "apple.swift-log");
        assert!(matches!(
            dependencies[1].requirement,
            Requirement::Range { .. }
        ));
        assert_eq!(dependencies[2].identity, "local-package");
        assert_eq!(dependencies[2].location, "/tmp/local-package");
        assert!(matches!(dependencies[2].requirement, Requirement::Exact(_)));
    }

    #[test]
    fn parses_only_manifest_dependencies_referenced_by_targets() {
        let manifest = json!({
            "dependencies": [
                {
                    "sourceControl": [
                        {
                            "identity": "swift-custom-dump",
                            "location": {
                                "remote": [
                                    { "urlString": "https://github.com/pointfreeco/swift-custom-dump.git" }
                                ]
                            },
                            "requirement": {
                                "range": [
                                    { "lowerBound": "1.0.0", "upperBound": "2.0.0" }
                                ]
                            }
                        }
                    ]
                },
                {
                    "sourceControl": [
                        {
                            "identity": "carton",
                            "location": {
                                "remote": [
                                    { "urlString": "https://github.com/swiftwasm/carton" }
                                ]
                            },
                            "requirement": {
                                "range": [
                                    { "lowerBound": "1.0.0", "upperBound": "2.0.0" }
                                ]
                            }
                        }
                    ]
                },
                {
                    "registry": [
                        {
                            "identity": "tuist.FileSystem",
                            "requirement": {
                                "range": [
                                    { "lowerBound": "0.18.0", "upperBound": "1.0.0" }
                                ]
                            }
                        }
                    ]
                }
            ],
            "targets": [
                {
                    "name": "App",
                    "type": "regular",
                    "dependencies": [
                        { "product": ["CustomDump", "swift-custom-dump", null, null] },
                        { "byName": ["FileSystem", null] }
                    ]
                }
            ],
            "products": [
                {
                    "name": "App",
                    "targets": ["App"],
                    "type": { "library": ["automatic"] }
                }
            ]
        });

        let dependencies = parse_required_manifest_dependencies(&manifest).unwrap();

        assert_eq!(dependencies.len(), 2);
        assert_eq!(dependencies[0].identity, "swift-custom-dump");
        assert_eq!(dependencies[1].identity, "tuist.FileSystem");
    }

    #[test]
    fn parses_swiftpm_file_system_dependencies() {
        let manifest = json!({
            "dependencies": [
                {
                    "fileSystem": [
                        {
                            "identity": "xcactivitylog_nif",
                            "path": "/repo/server/native/xcactivitylog_nif"
                        }
                    ]
                },
                {
                    "fileSystem": [
                        {
                            "identity": "xcresult_nif",
                            "nameForTargetDependencyResolutionOnly": "XCResultNIF",
                            "path": "/repo/server/native/xcresult_nif"
                        }
                    ]
                }
            ]
        });

        let dependencies = parse_manifest_file_system_dependencies(&manifest).unwrap();

        assert_eq!(dependencies.len(), 2);
        assert_eq!(dependencies[0].identity, "xcactivitylog_nif");
        assert_eq!(dependencies[0].name, "xcactivitylog_nif");
        assert_eq!(
            dependencies[0].path,
            "/repo/server/native/xcactivitylog_nif"
        );
        assert_eq!(dependencies[1].identity, "xcresult_nif");
        assert_eq!(dependencies[1].name, "XCResultNIF");
    }

    #[test]
    fn parses_package_resolved_v3() {
        let resolved: ResolvedPins = serde_json::from_value(json!({
            "originHash": "abc",
            "pins": [
                {
                    "identity": "alamofire",
                    "kind": "remoteSourceControl",
                    "location": "https://github.com/Alamofire/Alamofire",
                    "state": {
                        "revision": "0123456789abcdef",
                        "version": "5.10.2"
                    }
                }
            ],
            "version": 3
        }))
        .unwrap();

        assert_eq!(resolved.pins[0].identity, "alamofire");
        assert_eq!(checkout_directory_name(&resolved.pins[0]), "Alamofire");
        assert_eq!(
            cache_test_path(PathBuf::from("/tmp/cache"), &resolved.pins[0]),
            "5.10.2-0123456789ab"
        );
    }

    #[test]
    fn parses_registry_pins_without_revisions() {
        let resolved: ResolvedPins = serde_json::from_value(json!({
            "pins": [
                {
                    "identity": "apple.swift-log",
                    "kind": "registry",
                    "location": "",
                    "state": {
                        "version": "1.6.4"
                    }
                }
            ],
            "version": 3
        }))
        .unwrap();

        assert_eq!(resolved.pins[0].state.version.as_deref(), Some("1.6.4"));
        assert!(resolved.pins[0].revision().is_err());
    }

    #[test]
    fn strips_v_prefix_from_versions() {
        assert_eq!(
            parse_swift_tag_version("v1.2.3").unwrap(),
            Version::new(1, 2, 3)
        );
        assert_eq!(
            parse_swift_tag_version("1.2.3").unwrap(),
            Version::new(1, 2, 3)
        );
        assert!(parse_swift_tag_version("nightly").is_none());
    }

    #[test]
    fn pubgrub_solves_transitive_swift_semver_constraints() {
        let mut provider = PubgrubDependencyProvider::default();
        provider.add_versions("menu", vec![Version::new(1, 0, 0), Version::new(1, 1, 0)]);
        provider.add_versions("icons", vec![Version::new(1, 0, 0), Version::new(2, 0, 0)]);
        provider.add_dependencies(
            "menu",
            Version::new(1, 0, 0),
            vec![(
                SolverPackage::from("icons"),
                Ranges::between(Version::new(1, 0, 0), Version::new(2, 0, 0)),
            )],
        );
        provider.add_dependencies(
            "menu",
            Version::new(1, 1, 0),
            vec![(
                SolverPackage::from("icons"),
                Ranges::between(Version::new(2, 0, 0), Version::new(3, 0, 0)),
            )],
        );

        let solution = solve_pubgrub_dependencies(
            provider,
            vec![
                (
                    SolverPackage::from("menu"),
                    Ranges::between(Version::new(1, 0, 0), Version::new(2, 0, 0)),
                ),
                (
                    SolverPackage::from("icons"),
                    Ranges::between(Version::new(1, 0, 0), Version::new(2, 0, 0)),
                ),
            ],
        )
        .unwrap();

        assert_eq!(solution["menu"], Version::new(1, 0, 0));
        assert_eq!(solution["icons"], Version::new(1, 0, 0));
    }

    #[test]
    fn revision_and_branch_requirements_stay_outside_pubgrub() {
        assert!(version_range_for_requirement(&Requirement::Revision("abc".to_string())).is_none());
        assert!(version_range_for_requirement(&Requirement::Branch("main".to_string())).is_none());
        assert!(
            version_range_for_requirement(&Requirement::Exact(Version::new(1, 2, 3))).is_some()
        );
    }
}
