use anyhow::Result;
use codex_config::types::AuthKeyringBackendKind;
use codex_config::types::OAuthCredentialsStoreMode;
use pretty_assertions::assert_eq;

use super::TempCodexHome;
use super::sample_tokens;
use crate::oauth::ResolvedOAuthCredentialStore;
use crate::oauth::StoredOAuthCredentialSnapshot;
use crate::oauth::delete_oauth_tokens;
use crate::oauth::normalized_oauth_credentials;
use crate::oauth::save_oauth_tokens;
use crate::oauth::stored_oauth_credential_snapshot;
use crate::oauth::stored_oauth_credentials;

#[test]
fn auto_credentials_roundtrip_and_logout_without_keyring() -> Result<()> {
    let env = TempCodexHome::new();
    // A broken Secrets lock must not affect OHOS's File authority, even when
    // the caller selects the Secrets keyring backend.
    std::fs::create_dir_all(env.path().join("mcp-oauth-locks/secrets-store.lock"))?;
    let tokens = sample_tokens();
    let expected = normalized_oauth_credentials(Some(&tokens));
    let mode = OAuthCredentialsStoreMode::Auto;

    for backend in [
        AuthKeyringBackendKind::Direct,
        AuthKeyringBackendKind::Secrets,
    ] {
        save_oauth_tokens(&tokens.server_name, &tokens, mode, backend)?;
        assert_eq!(
            stored_oauth_credentials(&tokens.server_name, &tokens.url, mode, backend)?,
            expected,
        );
        let snapshot =
            stored_oauth_credential_snapshot(&tokens.server_name, &tokens.url, mode, backend)?
                .expect("Auto should load the persisted credentials");
        assert_eq!(snapshot.store, ResolvedOAuthCredentialStore::File);
        assert_eq!(
            StoredOAuthCredentialSnapshot::for_runtime_refresh(
                Some(&snapshot),
                &tokens.server_name,
                &tokens.url,
                mode,
                backend,
            )?,
            Some(snapshot.clone()),
        );
        assert_eq!(
            snapshot.reload(&tokens.server_name, &tokens.url, mode, backend)?,
            expected,
        );
        assert!(delete_oauth_tokens(
            &tokens.server_name,
            &tokens.url,
            mode,
            backend,
        )?);
        assert_eq!(
            stored_oauth_credentials(&tokens.server_name, &tokens.url, mode, backend)?,
            None,
        );
        assert!(!delete_oauth_tokens(
            &tokens.server_name,
            &tokens.url,
            mode,
            backend,
        )?);
    }
    Ok(())
}

#[test]
fn explicit_keyring_fails_without_touching_file_credentials() -> Result<()> {
    let _env = TempCodexHome::new();
    let tokens = sample_tokens();
    let expected = normalized_oauth_credentials(Some(&tokens));
    let mode = OAuthCredentialsStoreMode::Keyring;

    for backend in [
        AuthKeyringBackendKind::Direct,
        AuthKeyringBackendKind::Secrets,
    ] {
        save_oauth_tokens(
            &tokens.server_name,
            &tokens,
            OAuthCredentialsStoreMode::Auto,
            backend,
        )?;
        let snapshot = stored_oauth_credential_snapshot(
            &tokens.server_name,
            &tokens.url,
            OAuthCredentialsStoreMode::Auto,
            backend,
        )?
        .expect("Auto credentials should remain available");
        let failures = [
            save_oauth_tokens(&tokens.server_name, &tokens, mode, backend)
                .expect_err("explicit Keyring save must fail"),
            stored_oauth_credentials(&tokens.server_name, &tokens.url, mode, backend)
                .expect_err("explicit Keyring load must fail"),
            snapshot
                .reload(&tokens.server_name, &tokens.url, mode, backend)
                .expect_err("explicit Keyring reload must fail"),
            StoredOAuthCredentialSnapshot::for_runtime_refresh(
                /*previous*/ None,
                &tokens.server_name,
                &tokens.url,
                mode,
                backend,
            )
            .expect_err("explicit Keyring refresh must fail"),
            delete_oauth_tokens(&tokens.server_name, &tokens.url, mode, backend)
                .expect_err("explicit Keyring logout must fail"),
        ];
        for error in failures {
            assert!(error.to_string().contains("unsupported on OpenHarmony"));
        }
        assert_eq!(
            stored_oauth_credentials(
                &tokens.server_name,
                &tokens.url,
                OAuthCredentialsStoreMode::File,
                backend,
            )?,
            expected,
        );
    }
    Ok(())
}
