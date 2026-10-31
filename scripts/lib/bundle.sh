#!/bin/sh

ca_bundle_split() {
    local input output_dir
    input=$1
    output_dir=$2
    awk -v dir="$output_dir" '
        BEGIN { count = 0; inside = 0; invalid = 0 }
        {
            sub(/\r$/, "")
            if ($0 == "-----BEGIN CERTIFICATE-----") {
                if (inside) invalid = 1
                count++
                file = sprintf("%s/cert-%05d.pem", dir, count)
                inside = 1
                print > file
                next
            }
            if ($0 == "-----END CERTIFICATE-----") {
                if (!inside) invalid = 1
                if (inside) print >> file
                close(file)
                inside = 0
                next
            }
            if (inside) {
                print >> file
                next
            }
            if ($0 ~ /^-----BEGIN / || $0 ~ /^-----END /) invalid = 1
        }
        END {
            if (inside || invalid || count == 0) exit 1
        }
    ' "$input"
}

ca_bundle_validate() {
    [ -s "$1" ] || return 1
    openssl crl2pkcs7 -nocrl -certfile "$1" -outform PEM -out /dev/null >/dev/null 2>&1
}

ca_bundle_add_selected_pem() {
    local input output seen require_ca allowed_hashes temp_dir selected certificate details fingerprint
    input=$1
    output=$2
    seen=$3
    require_ca=$4
    allowed_hashes=$5
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ca-bundle.XXXXXX") || return 1

    if ! ca_bundle_split "$input" "$temp_dir"; then
        echo "Invalid PEM certificate bundle: $input" >&2
        rm -rf "$temp_dir"
        return 1
    fi

    : >> "$output"
    : >> "$seen"
    selected=0
    for certificate in "$temp_dir"/*.pem; do
        openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || {
            echo "Invalid X.509 certificate in $input" >&2
            rm -rf "$temp_dir"
            return 1
        }
        if [ "$require_ca" = yes ]; then
            details=$(openssl x509 -in "$certificate" -noout -text 2>/dev/null) || {
                rm -rf "$temp_dir"
                return 1
            }
            printf '%s\n' "$details" | grep -q 'CA:TRUE' || {
                echo "Custom certificate is not a CA: $certificate" >&2
                rm -rf "$temp_dir"
                return 1
            }
        fi

        fingerprint=$(openssl x509 -in "$certificate" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
        case "$fingerprint" in
            ''|*[!0-9a-f]*)
                echo "Could not fingerprint certificate in $input" >&2
                rm -rf "$temp_dir"
                return 1
                ;;
        esac

        if [ -n "$allowed_hashes" ] && ! grep -Fxq "$fingerprint" "$allowed_hashes"; then
            continue
        fi
        selected=$((selected + 1))
        if ! grep -Fxq "$fingerprint" "$seen"; then
            printf '%s\n' "$fingerprint" >> "$seen"
            cat "$certificate" >> "$output"
        fi
    done

    rm -rf "$temp_dir"
    [ "$selected" -gt 0 ]
}

ca_bundle_add_pem() {
    ca_bundle_add_selected_pem "$1" "$2" "$3" "$4" ""
}

ca_bundle_add_chrome() {
    local certificates store_markdown output seen temp_hashes trusted_count chrome_bundle chrome_seen chrome_count result
    certificates=$1
    store_markdown=$2
    output=$3
    seen=$4
    temp_hashes=$(mktemp "${TMPDIR:-/tmp}/chrome-roots.XXXXXX") || return 1

    awk -F '|' '
        /^## Trusted Roots/ { trusted = 1; next }
        /^## Constrained Roots/ { trusted = 0 }
        trusted {
            hash = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", hash)
            if (length(hash) == 64 && hash ~ /^[0-9a-fA-F]+$/) print tolower(hash)
        }
    ' "$store_markdown" > "$temp_hashes"
    sort -u "$temp_hashes" -o "$temp_hashes"

    if [ ! -s "$temp_hashes" ]; then
        echo "Chrome root store has no parseable trusted-root hashes" >&2
        rm -f "$temp_hashes"
        return 1
    fi

    trusted_count=$(wc -l < "$temp_hashes" | tr -d ' ')
    chrome_bundle=$(mktemp "${TMPDIR:-/tmp}/chrome-bundle.XXXXXX") || { rm -f "$temp_hashes"; return 1; }
    chrome_seen=$(mktemp "${TMPDIR:-/tmp}/chrome-seen.XXXXXX") || { rm -f "$temp_hashes" "$chrome_bundle"; return 1; }
    : > "$chrome_seen"
    if ! ca_bundle_add_selected_pem "$certificates" "$chrome_bundle" "$chrome_seen" no "$temp_hashes"; then
        rm -f "$temp_hashes" "$chrome_bundle" "$chrome_seen"
        return 1
    fi
    chrome_count=$(wc -l < "$chrome_seen" | tr -d ' ')
    if [ "$chrome_count" != "$trusted_count" ]; then
        echo "Chrome root snapshot is incomplete ($chrome_count of $trusted_count trusted roots found)" >&2
        rm -f "$temp_hashes" "$chrome_bundle" "$chrome_seen"
        return 1
    fi
    rm -f "$temp_hashes" "$chrome_seen"
    ca_bundle_add_pem "$chrome_bundle" "$output" "$seen" no
    result=$?
    rm -f "$chrome_bundle"
    return "$result"
}
