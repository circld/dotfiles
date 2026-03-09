function hm-refresh --description 'Re-source home-manager session variables (for use after home-manager switch)'
    set -e __HM_SESS_VARS_SOURCED
    set -l vars_file (string match -r '/nix/store/[^ ]+hm-session-vars\.fish' < ~/.config/fish/config.fish)
    if test -n "$vars_file"
        source $vars_file
    end
end
