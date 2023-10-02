/**
	SeaHash hash function.

	The code is based on the Go implementation at https://github.com/dim13/seahash/

	Copyright: © 2023 Sönke Ludwig, © 2016 Dimitri Sokolyuk <demon@dim13.org>
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.container.seahash;

@safe nothrow pure @nogc:

SeaHashDigest.Result seaHash(scope const(ubyte)[] bytes)
{
	SeaHashDigest d;
	d.put(bytes);
	return d.finish();
}


SeaHashDigest.Result seaHash(scope const(char)[] string)
{
	return seaHash(cast(const(ubyte)[])string);
}

unittest {
	struct S {
		string s;
		ulong n;
	}
	S[2] cases = [
		{"to be or not to be", 1988685042348123509},
		{"love is a wonderful terrible thing", 4784284276849692846}
	];
	foreach (c; cases)
		assert(seaHash(c.s) == c.n, c.s);
}

struct SeaHashDigest {
	alias Result = ulong;
	enum blockSize = Result.sizeof;

	ulong a = 0x16f11fe89b0d677c;
	ulong b = 0xb480a793d8e6c86c;
	ulong c = 0x6fe2e5aaf078ebc9;
	ulong d = 0x14f994a4c5259381;
	ulong n = 0;

	@safe nothrow pure @nogc:

	Result finish()
	const {
		return diffuse(a ^ b ^ c ^ d ^ n);
	}

	void put(scope const(ubyte)[] p)
	{
		n += p.length;

		while (p.length >= blockSize) {
			addBlock(ulong(p[0]) | ulong(p[1]) << 8 | ulong(p[2]) << 16
				| ulong(p[3]) << 24 | ulong(p[4]) << 32 | ulong(p[5]) << 40
				| ulong(p[6]) << 48 | ulong(p[7]) << 56);
			p = p[blockSize .. $];
		}

		if (p.length) {
			ulong x = 0;
			foreach_reverse(v; p) {
				x <<= 8;
				x |= ulong(v);
			}
			addBlock(x);
		}
	}

	private void addBlock(ulong x)
	{
		auto newd = diffuse(a ^ x);
		a = b;
		b = c;
		c = d;
		d = newd;
	}
}

private ulong diffuse(ulong x)
{
	x *= 0x6eed0e9da4d94a4f;
	x ^= (x >> 32) >> (x >> 60);
	x *= 0x6eed0e9da4d94a4f;
	return x;
}
