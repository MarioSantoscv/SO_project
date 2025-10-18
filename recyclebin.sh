#!/bin/bash


#TODO: add header, add comments to functions, finish doing the functions, write a test script and a readme file 
#in the readme explain what all of the metadad bits are 
initialize_recyclebin() {
    RECYCLE_BIN="$HOME/.recycle_bin"
    FILES_DIR="$RECYCLE_BIN/files"
    METADATA_LOG="$RECYCLE_BIN/metadata.log"
    CONFIG="$RECYCLE_BIN/config"
    LOG="$RECYCLE_BIN/recyclebin.log"

    # create directories
    if ! mkdir -p "$FILES_DIR"; then
        echo "ERROR: Unable to create recycle bin directories at $FILES_DIR"
        return 1
    fi

    # initialize metadata.db with CSV header if missing or empty (matches the metadata log format of delete_file function)

    # header: deletion_timestamp,uuid,original_path,recycle_path,permissions,owner,group,atime,mtime,ctime
    if [ ! -f "$METADATA_LOG" ] || [ ! -s "$METADATA_LOG" ]; then
        if ! printf 'deletion_timestamp,uuid,original_path,recycle_path,permissions,owner,group,atime,mtime,ctime\n' > "$METADATA_LOG"; then
            echo "ERROR: Unable to create $METADATA_LOG"
            return 1
        fi
    fi

    # create default config file only if it does not exist
    if [ ! -f "$CONFIG" ]; then
        if ! printf 'MAX_SIZE_MB=1024\nRETENTION_DAYS=30\n' > "$CONFIG"; then
            echo "ERROR: Unable to create config file $CONFIG"
            return 1
        fi
    fi

    # create empty recyclebin.log if not it does not exist (used touch just to make sure i wouldnt alter the file if it already existed)
    if ! touch "$LOG"; then 
        echo "ERROR: Unable to create log file $LOG"
        return 1
    fi

    return 0
}


function delete_file(){
    
    
    #error handling: making sure user passes at least one file/dir as an argument
    if [ $# -eq 0 ]; then
        echo "usage: delete_file <file_or_folder>"
        return 1
    fi

    for path in "$@"; do 
        if [ ! -e "$path" ]; then 
        echo "File or directory does not exist: $path"
        continue
        fi

        # To make sure we cant delete the recycle bin or its contents
        abs_path="$(realpath "$path")"
        if [[ "$abs_path" == "$RECYCLE_BIN"* ]]; then
            echo "Error: cannot delete recycle bin or its contents: $path"
            continue
        fi

        #Permisson checks: (done in order of comments)
        #Regular files check read
        #DIRs check execute
        #also check if destination is writable 
        if [ -f "$path" ]; then
            if [ ! -r "$path" ]; then
                echo "Error: Permission denied for $path"
                continue
            fi
        elif [ -d "$path" ]; then
            if [ ! -x "$path" ]; then
                echo "Error: Permission denied for directory $path (no execute permission)"
                continue
            fi
        fi

        
        if [ ! -w "$FILES_DIR" ]; then
            echo "Error: Cannot write to recycle bin destination: $FILES_DIR"
            continue
        fi

        #preparing the file information for recycling
    
        abs_path="$(realpath "$path")" 
        base_name="$(basename "$path")"
        uuid_str="$(uuidgen)"
        ts="$(date +%d%m%Y%H%M%S)"
        recycle_name="${base_name}_${uuid_str}"
        dest_path="$FILES_DIR/$recycle_name"
        
        #Storing metadata (perrmissions, timestamps, owners)
        #(check stat --help for more info on formatting options)

        perms=$(stat -c '%a' "$path")
        owner=$(stat -c '%U' "$path")
        group=$(stat -c '%G' "$path")
        atime=$(stat -c '%X' "$path") #last acess time
        mtime=$(stat -c '%Y' "$path") #last modification time
        ctime=$(stat -c '%Z' "$path") #last change time


        #getting file size and type (done by copilot)
        if [ -d "$path" ]; then
            ftype="directory"
            if du -sb "$path" >/dev/null 2>&1; then
                size=$(du -sb "$path" | cut -f1)
            else
                size_kb=$(du -s "$path" | cut -f1)
                size=$((size_kb * 1024))
            fi
        else
            ftype="file"
            size=$(stat -c '%s' "$path" 2>/dev/null || printf '0')
        fi


        #moving the file/dir

        if mv -- "$path" "$dest_path"; then
            echo "Recycled: $abs_path -> $dest_path"
            echo "$ts|$uuid_str|$base_name|$abs_path|$dest_path|$size|$ftype|$perms|$owner_group|$atime|$mtime|$ctime" >> "$METADATA_LOG" || \
            echo "Warning: failed to write metadata for $path"
            echo "$(date +"%Y-%m-%d %H:%M:%S") MOVED $abs_path -> $dest_path size=${size} type=${ftype} uuid=${uuid_str}" >> "$LOG" 2>/dev/null
        else
            echo "Error: Failed to move $path to recycle bin."
            echo "$(date +"%Y-%m-%d %H:%M:%S") FAILED_MOVE $abs_path -> $dest_path" >> "$LOG" 2>/dev/null
        fi
    done


}
function list_recycled(){

    #I wanted to add a sorting flag to the function and made it sortable by date of deletion, name or size

    sort_by="date" #default sorting by date of deletion
    detailed=0
    while [[ $# -gt 0 ]]; do
        case $1 in
            --sort)
                sort_by="$2"
                shift 2 #removing the flag and its argument just to make handling easier if necessary (done by copilot)
                ;;
            --detailed)
                detailed=1
                shift
                ;;
            *)
                echo "Usage: list_recycled [--sort <date|name|size>] [--detailed]"
                return 1
                ;;
        esac
    done
    if [ ! -f "$METADATA_LOG" ]; then
        echo "No files in recycle bin."
        return 0
    fi

    #helper function for human readable bytes
    human_readable() {
        local bytes=$1
        if [ "$bytes" -lt 1024 ]; then
            echo "${bytes}B"
        elif [ "$bytes" -lt $((1024*1024)) ]; then
            printf "%dKB" $((bytes / 1024))
        elif [ "$bytes" -lt $((1024*1024*1024)) ]; then
            printf "%dMB" $((bytes / 1024 / 1024))
        else
            printf "%dGB" $((bytes / 1024 / 1024 / 1024))
        fi
    }

   

    entries=()
    total_count=0
    total_bytes=0

    # read metadata lines one by one
    while IFS= read -r line || [ -n "$line" ]; do
        #skip empty lines
        [ -z "$line" ] && continue

        # expected format from the delete_file function:
        IFS='|' read -r ts uuid orig_path rec_path perms owner group atime mtime ctime <<< "$line"

    
        # only include items that currently exist in the recycle bin
        [ -e "$rec_path" ] || continue

        # size: files -> stat, directories -> du -sk (KB) converted to bytes using integer math (no awk)(done by copilot)
       if du -sb "$rec_path"; then
        size_bytes=$(du -sb "$rec_path" | cut -f1)
        else
            echo "du failed on $rec_path" >&2
            size_bytes=0
        fi


        # convert timestamp ddmmyyyyHHMMSS -> "YYYY-MM-DD HH:MM:SS" (if matches expected format)
        if [[ $ts =~ ^[0-9]{14}$ ]]; then
            del_date="${ts:4:4}-${ts:2:2}-${ts:0:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}"
        else
            del_date="$ts"
        fi

        uid_short="${uuid:0:8}" #did this because uuids are very long so i decided to use a more compact form (used 8 chars just because it looks good and the odds of collision are slim)
        name="$(basename "$orig_path")"
        size_hr="$(human_readable "$size_bytes")"

        # store an entry with this format: uid_short|name|del_date|size_bytes|size_hr|uuid|orig_path|rec_path|perms|owner|group|atime|mtime|ctime
        entries+=( "$uid_short|$name|$del_date|$size_bytes|$size_hr|$uuid|$orig_path|$rec_path|$perms|$owner|$group|$atime|$mtime|$ctime" )
        total_count=$(( total_count + 1 ))
        total_bytes=$(( total_bytes + size_bytes ))
    done < "$METADATA_LOG"

    if [ ${#entries[@]} -eq 0 ]; then
        echo "No recycled items found."
        return 0
    fi

    # choose sort option (date: newest first) (help of copilot)
    case "$sort_by" in
        name) sort_args=(-t'|' -k2,2) ;;          
        size) sort_args=(-t'|' -k4,4nr) ;;        
        date) sort_args=(-t'|' -k3,3r) ;;        
        *)
            echo "Invalid sort option. Valid options are: date, name, size."
            return 1
            ;;
    esac

    if [ "$detailed" -eq 0 ]; then
        #header of the compact table when view set to normal
        printf "%-10s %-25s %-20s %-8s\n" "ID" "Name" "Deleted" "Size"
        printf "%-10s %-25s %-20s %-8s\n" "----------" "-------------------------" "--------------------" "--------"

        # sort and print
        printf "%s\n" "${entries[@]}" | sort "${sort_args[@]}" | while IFS='|' read -r uid_short name del_date size_bytes size_hr _rest; do
            printf "%-10s %-25.25s %-20s %-8s\n" "$uid_short" "$name" "$del_date" "$size_hr"
        done
    else
        # detailed view
        printf "Detailed view of recycled items (sorted by %s):\n\n" "$sort_by"
        printf "%s\n" "${entries[@]}" | sort "${sort_args[@]}" | while IFS='|' read -r uid_short name del_date size_bytes size_hr uuid orig_path rec_path perms owner group atime mtime ctime; do
            printf "UUID: %s\n" "$uuid"
            printf "ID (short): %s\n" "$uid_short"
            printf "Name: %s\n" "$name"
            printf "Original path: %s\n" "$orig_path"
            printf "Recycle path: %s\n" "$rec_path"
            printf "Deleted: %s\n" "$del_date"
            printf "Size: %s (%d bytes)\n" "$size_hr" "$size_bytes"
            printf "Permissions: %s\n" "$perms"
            printf "Owner: %s   Group: %s\n" "$owner" "$group"
            printf "Accessed: %s   Modified: %s   Changed: %s\n" "$atime" "$mtime" "$ctime"
            printf "----\n"
        done
    fi

    # totals
    total_hr="$(human_readable "$total_bytes")"
    echo
    printf "Total items: %d\n" "$total_count"
    printf "Total size: %s (%d bytes)\n" "$total_hr" "$total_bytes"

}
function restore_file() {
    # Restore a recycled item by ID (uuid or short prefix) or filename.
    # Uses METADATA_LOG and RECYCLE_BIN variables from the surrounding script.
    #
    # Expected metadata line format:
    # ts|uuid|original_path|recycle_path|perms|owner|group|atime|mtime|ctime

    local lookup="$1"
    local matches=()
    local idx=0

    if [ -z "$lookup" ]; then
        echo "Usage: restore_file <UUID-or-short-id-or-filename>"
        return 1
    fi

    if [ ! -f "$METADATA_LOG" ]; then
        echo "No metadata log found: $METADATA_LOG"
        return 1
    fi

    # collect matches
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        IFS='|' read -r ts uuid orig_path rec_path perms owner group atime mtime ctime <<< "$line"

        # see if fields are not empty
        [ -z "$uuid" ] && continue
        [ -z "$rec_path" ] && continue

        local base_name
        base_name="$(basename "$orig_path")"

        if [ "$lookup" = "$uuid" ] || [[ "$uuid" == "$lookup"* ]] || [ "$lookup" = "$base_name" ] || [ "$lookup" = "$orig_path" ]; then
            matches+=("$line")
        fi
    done < "$METADATA_LOG"

    if [ ${#matches[@]} -eq 0 ]; then
        echo "No entry found matching '$lookup' in $METADATA_LOG"
        return 1
    fi

    # if multiple matches, let user choose which one to restore
    local chosen_line
    if [ ${#matches[@]} -gt 1 ]; then
        echo "Multiple matches found:"
        for i in "${!matches[@]}"; do
            IFS='|' read -r ts uuid orig_path rec_path perms owner group atime mtime ctime <<< "${matches[i]}"
            # readable timestamp if possible (ddmmyyyyHHMMSS -> YYYY-MM-DD HH:MM:SS)
            if [[ $ts =~ ^[0-9]{14}$ ]]; then
                del_date="${ts:4:4}-${ts:2:2}-${ts:0:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}" #same as in list_recycled
            else
                del_date="$ts"
            fi
            size_bytes=0
            if [ -e "$rec_path" ]; then
                if [ -d "$rec_path" ]; then
                    size_kb=$(du -sk "$rec_path" 2>/dev/null | cut -f1) #reports size in kb and cuts only the numeric part
                    size_bytes=$(( ${size_kb:-0} * 1024 ))  #1 byte = 1024kb
                else
                    size_bytes=$(stat -c '%s' "$rec_path" 2>/dev/null || echo 0) #if a file just get the size in bytes
                fi
            fi
            #using my function human_readable if it exists to convert bytes to human readable format (hr format)
            if declare -f human_readable >/dev/null 2>&1; then
                size_hr=$(human_readable "$size_bytes")
            else
                size_hr="${size_bytes}B"
            fi
            echo "[$i] ID=${uuid:0:8}  Name=$(basename "$orig_path")  Deleted=$del_date  Size=$size_hr  RecyclePath=$rec_path"
        done

        # Selection loop of the item to restore (validates input to numeric and less than number of matches)
        while true; do
            read -rp "Select index to restore (or 'c' to cancel): " selected
            [ "$selected" = "c" ] && echo "Cancelled." && return 0
            if [[ "$selected" =~ ^[0-9]+$ ]] && [ "$selected" -ge 0 ] && [ "$selected" -lt "${#matches[@]}" ]; then
                chosen_line="${matches[selected]}"
                break
            fi
            echo "Invalid selection."
        done
    else
        chosen_line="${matches[0]}"
    fi

    
    IFS='|' read -r ts uuid orig_path rec_path perms owner group atime mtime ctime <<< "$chosen_line"

    
    if [ ! -e "$rec_path" ]; then
        echo "Recycled item not found at: $rec_path"
        return 1
    fi

    # using the same size calculation method to see if there is enough space to restore
    if [ -d "$rec_path" ]; then
        size_kb=$(du -sk "$rec_path" 2>/dev/null | cut -f1)
        size_bytes=$(( ${size_kb:-0} * 1024 ))
    else
        size_bytes=$(stat -c '%s' "$rec_path" 2>/dev/null || echo 0)
    fi

    # ensure parent dir exists (create if necessary)
    dest_parent="$(dirname "$orig_path")"
    if [ ! -d "$dest_parent" ]; then
        echo "Parent directory $dest_parent does not exist."
        read -rp "Create parent directories and continue? [y/N]: " yn
        case "$yn" in
            [Yy]* ) mkdir -p "$dest_parent" || { echo "Failed to create $dest_parent (permission?)"; return 1; } ;;
            * ) echo "Cancelled."; return 0 ;; #if no just exit
        esac
    fi

    # check disk space on destination filesystem
    avail_kb=$(df -P -k "$dest_parent" 2>/dev/null | awk 'END{print $4+0}') #(copilot helped)
    need_kb=$(( (size_bytes + 1023) / 1024 ))
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$need_kb" ]; then
        echo "Not enough disk space to restore (need ${need_kb}K, have ${avail_kb}K)."
        return 1
    fi

    dest="$orig_path"
    # handle conflicts if destination exists
    if [ -e "$dest" ]; then
        echo "A file or directory already exists at $dest"
        action="Choose action: "
        options=("Overwrite" "Restore with modified name" "Cancel")
        select opt in "${options[@]}"; do
            case "$REPLY" in
                1)
                    # Overwrite: remove existing (prompt for final confirmation)
                    read -rp "Are you sure you want to overwrite $dest ? [y/N]: " ok
                    case "$ok" in
                        [Yy]* )
                            # try to remove existing
                            if rm -rf -- "$dest"; then  #recursive remove for dirs, force for files
                                echo "Existing item removed."
                                break
                            else
                                echo "Failed to remove existing item (permission?)."
                                return 1
                            fi
                            ;;
                        *)
                            echo "Cancelled by user."
                            return 0
                            ;;
                    esac
                    ;;
                2)
                    # create modified name by appending timestamp
                    ts_now=$(date +%s)
                    dest="${orig_path}_restored_${ts_now}"
                    echo "Will restore to: $dest"
                    break
                    ;;
                3)
                    echo "Cancelled."
                    return 0
                    ;;
                *)
                    echo "Invalid selection."
                    ;;
            esac
        done
    fi

    # perform the move
    if mv -- "$rec_path" "$dest"; then
        echo "Restored: $dest"
        # restore perms
        if [ -n "$perms" ]; then
            chmod "$perms" "$dest" 2>/dev/null || echo "Warning: chmod failed for $dest"
        fi

        # remove the metadata line (matching the exact UUID) (done by copilot)
        tmpf="$(mktemp "${RECYCLE_BIN:-/tmp}/restore.XXXXXXXX")" || tmpf="/tmp/restore.$$"
        awk -F'|' -v id="$uuid" '$2 != id { print }' "$METADATA_LOG" > "$tmpf" && mv "$tmpf" "$METADATA_LOG" || {
            echo "Warning: failed to update metadata log; metadata may still reference the restored item."
            [ -f "$tmpf" ] && rm -f "$tmpf"
        }

        # log operation
        LOG="${RECYCLE_BIN:-$HOME/.recycle_bin}/recyclebin.log"
        echo "$(date +"%Y-%m-%d %H:%M:%S") RESTORED $uuid -> $dest size=${size_bytes}" >> "$LOG" 2>/dev/null

        echo "Restore complete."
        return 0
    else
        echo "Failed to move $rec_path -> $dest (permission or filesystem error)."
        echo "$(date +"%Y-%m-%d %H:%M:%S") FAILED_RESTORE $uuid -> $dest" >> "${RECYCLE_BIN:-$HOME/.recycle_bin}/recyclebin.log" 2>/dev/null
        return 1
    fi
}
function search_recycled(){
    local case_insensitive=0
    local pattern

    while [[ $# -gt 0 ]]; do 
        case "$1" in 
            -i|--ignore-case)
                case_insensitive=1; shift ;;
            -h|--help)
                echo "Usage: search_recycled [-i|--ignore-case] <pattern>"
                echo "Examples:"
                echo "  search_recycled \"report\""
                echo "  search_recycled \"*.pdf\""
                return 0
                ;;
            -*) printf "Unknown option: %s\n" "$1"
                return 1
                ;;
            *) break;;
        esac
    done

    #remaining arguments are the pattern now
    pattern="$*"

    if [ -z "$pattern" ]: then 
        echo "Usage: search_recycled [-i|--ignore-case] <pattern>"
        return 1
    fi

    local metadata_file="$METADATA_LOG"
    if [ -z "$metadata_file" ]; then
        metadata_file="${RECYCLE_BIN:-$HOME/.recycle_bin}/metadata.log"
    fi

    if [ ! -f "$metadata_file" ]; then 
        echo "No metadata file found at: $metadata_file"
        return 1
    fi

    local search_expr
    local mode_flag
    if [[ "$pattern" == *"*"* ]]; then 
        #converting the * into .* for regex use
        search_expr="${pattern//\*/.*}"
        mode_flag= "-E" #-E, --extended-regexp     PATTERNS are extended regular expressions
    else
        search_expr="$pattern"
        mode_flag="-F" #-F, --fixed-strings       PATTERNS are strings
    fi


    #building the grep options (case insensitive or not)
    local grep_opts="$mode_flag"
    if [ "$case_insensitive" -eq 1 ]; then
        grep_opts+=" -i"
    fi

    local matches=()
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue

        # skip CSV header if present(since i dont want to match the header)
        #check initialize function for the header format( it starts with deletion_timestamp)
        case "$line" in
            deletion_timestamp*|deletion_timestamp,* ) continue ;;
        esac

        IFS='|' read -ra fields <<< "$line" #(-a flag turns it into an array for easier handling)
        local ts="${fields[0]:-}"
        local uuid="${fields[1]:-}"
        local base="${fields[2]:-}"
        local orig="${fields[3]:-}"
        local rec="${fields[4]:-}"

        if [ -z "$orig" ]; then 
            continue
        fi
        
        if [-z "$base" ]; then
            base="$(basename "$orig")"
        fi

        local matched=0
        
        #actual searching logic using grep (copilot recomended using the flags -q for quiet and -- for end of options)
        if [ -n "$base" ] && printf '%s\n' "$base" | grep $grep_opts -q -- "$search_expr"; then
            matched=1
        fi
        if [ $matched -eq 0 ] && [ -n "$orig" ] && printf '%s\n' "$orig" | grep $grep_opts -q -- "$search_expr"; then
            matched=1
        fi

        if [ $matched -eq 1 ]; then
            local del_date
            if [[ $ts =~ ^[0-9]{14}$ ]]; then
                del_date="${ts:4:4}-${ts:2:2}-${ts:0:2} ${ts:8:2}:${ts:10:2}:${ts:12:2}"
            else
                del_date="$ts"
            fi
            local uid_short="${uuid:0:8}"
            matches+=( "$uid_short|$base|$orig|$rec|$del_date|$uuid" )
        fi
    done < "$metadata_file"

    if [ ${#matches[@]} -eq 0 ]; then
        echo "No matches found for '$pattern'."
        return 0
    fi

    #print results in a table format

    printf "%-10s %-25s %-50s %-20s\n" "ID" "Name" "Original Path" "Deleted"
    printf "%-10s %-25s %-50s %-20s\n" "----------" "-------------------------" "--------------------------------------------------" "--------------------"

    for entry in "${matches[@]}"; do
        IFS='|' read -r id name orig rec del uuid <<< "$entry"
        printf "%-10s %-25.25s %-50.50s %-20s\n" "$id" "${name:-}" "${orig:-}" "${del:-}"
    done

    printf "\nTotal matches: %d\n" "${#matches[@]}"
    return 0

}
