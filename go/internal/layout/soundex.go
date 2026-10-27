package layout

// soundexDigit maps A–Z to American Soundex digits; 0 = vowel-like (dropped),
// 'h' marks H/W, which do not separate equal codes.
var soundexDigit = [26]byte{
	'0', '1', '2', '3', '0', '1', '2', 'h', '0', '2', '2', '4', '5',
	'5', '0', '1', '2', '6', '2', '3', '0', '1', 'h', '2', '0', '2',
}

// SoundexInto writes the 4-character American Soundex code of name into dst
// without allocating. Non-letters are ignored. It returns false when the name
// has no letters.
func SoundexInto(dst *[4]byte, name []byte) bool {
	n := 0
	var last byte
	for _, c := range name {
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		if c < 'A' || c > 'Z' {
			continue
		}
		d := soundexDigit[c-'A']
		if n == 0 {
			dst[0] = c
			n = 1
			if d == 'h' {
				d = '0'
			}
			last = d
			continue
		}
		switch d {
		case 'h':
			continue // H and W keep the previous code
		case '0':
			last = '0'
			continue
		}
		if d == last {
			continue
		}
		dst[n] = d
		n++
		last = d
		if n == 4 {
			return true
		}
	}
	if n == 0 {
		return false
	}
	for ; n < 4; n++ {
		dst[n] = '0'
	}
	return true
}

// Soundex returns the Soundex code of name, or "" if it has no letters.
func Soundex(name string) string {
	var d [4]byte
	if !SoundexInto(&d, []byte(name)) {
		return ""
	}
	return string(d[:])
}
