/**
	Internal hash map implementation.

	Copyright: © 2013-2023 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.container.hashmap;

import vibe.container.seahash : seaHash;
import vibe.container.internal.utilallocator;
import vibe.container.internal.rctable;

import std.traits;


struct DefaultHashMapTraits(Key) {
	enum clearValue = Key.init;
	static bool equals(in Key a, in Key b)
	{
		static if (__traits(isFinalClass, Key) && &Unqual!Key.init.opEquals is &Object.init.opEquals)
			return a is b;
		else static if (is(Key == class))
			// BUG: improperly casting away const
			return () @trusted { return a is b ? true : (a !is null && (cast(Object) a).opEquals(cast(Object) b)); }();
		else return a == b;
	}

	static size_t hashOf(const scope ref Key k)
	@safe {
		static if (__traits(isFinalClass, Key) && &Unqual!Key.init.toHash is &Object.init.toHash)
			return () @trusted { return cast(size_t)cast(void*)k; } ();
		else static if (__traits(compiles, Key.init.toHash()))
			return () @trusted { return (cast(Key)k).toHash(); } ();
		else static if (__traits(compiles, Key.init.toHashShared()))
			return k.toHashShared();
		else static if (__traits(isScalar, Key))
			return cast(size_t)k;
		else static if (isArray!Key && is(Key : E[], E) && __traits(isScalar, E))
			return cast(size_t)seaHash(cast(const(ubyte)[])k);
		else {
			// evil casts to be able to get the most basic operations of
			// HashMap nothrow and @nogc
			static size_t hashWrapper(const scope ref Key k) {
				static typeinfo = typeid(Key);
				return typeinfo.getHash(&k);
			}
			static @nogc nothrow size_t properlyTypedWrapper(const scope ref Key k) { return 0; }
			return () @trusted { return (cast(typeof(&properlyTypedWrapper))&hashWrapper)(k); } ();
		}
	}
}

unittest
{
	final class Integer : Object {
		public const int value;

		this(int x) @nogc nothrow pure @safe { value = x; }

		override bool opEquals(Object rhs) const @nogc nothrow pure @safe {
			if (auto r = cast(Integer) rhs)
				return value == r.value;
			return false;
		}

		override size_t toHash() const @nogc nothrow pure @safe {
			return value;
		}
	}

	auto hashMap = HashMap!(Object, int)(vibeThreadAllocator());
	foreach (x; [2, 4, 8, 16])
		hashMap[new Integer(x)] = x;
	foreach (x; [2, 4, 8, 16])
		assert(hashMap[new Integer(x)] == x);
}

struct HashMap(TKey, TValue, Traits = DefaultHashMapTraits!TKey, Allocator = IAllocator)
	if (is(typeof(Traits.clearValue) : TKey))
{
	import core.memory : GC;
	import vibe.container.internal.traits : isOpApplyDg;
	import std.algorithm.iteration : filter, map;

	alias Key = TKey;
	alias Value = TValue;

	struct TableEntry {
		UnConst!Key key = Traits.clearValue;
		Value value;

		this(ref Key key, ref Value value)
		{
			import std.algorithm.mutation : move;
			this.key = cast(UnConst!Key)key;
			static if (is(typeof(value.move)))
				this.value = value.move;
			else this.value = value;
		}
	}

	alias Table = RCTable!(TableEntry, Allocator);

	private {
		Table m_table;
		size_t m_length;
		bool m_resizing;
	}

	static if (!is(typeof(Allocator.instance))) {
		this(Allocator allocator)
		{
			m_table = Table(allocator);
		}
	}

	@property size_t length() const { return m_length; }

	void remove(Key key)
	{
		import std.algorithm.mutation : move;

		makeUnique();

		auto idx = findIndex(key);
		assert (idx != size_t.max, "Removing non-existent element.");
		auto i = idx;
		while (true) {
			m_table[i].key = Traits.clearValue;
			m_table[i].value = Value.init;

			size_t j = i, r;
			do {
				if (++i >= m_table.length) i -= m_table.length;
				if (Traits.equals(m_table[i].key, Traits.clearValue)) {
					m_length--;
					return;
				}
				r = Traits.hashOf(m_table[i].key) & (m_table.length-1);
			} while ((j<r && r<=i) || (i<j && j<r) || (r<=i && i<j));
			static if (is(typeof(m_table[i].move)))
				m_table[j] = m_table[i].move;
			else m_table[j] = m_table[i];
		}
	}

	Value get(Key key, lazy Value default_value = Value.init)
	{
		auto idx = findIndex(key);
		if (idx == size_t.max) return default_value;
		return m_table[idx].value;
	}

	/// Workaround #12647
	package(vibe) Value getNothrow(Key key, Value default_value = Value.init)
	{
		auto idx = findIndex(key);
		if (idx == size_t.max) return default_value;
		return m_table[idx].value;
	}

	static if (!is(typeof({ Value v; const(Value) vc; v = vc; }))) {
		const(Value) get(Key key, lazy const(Value) default_value = Value.init)
		{
			auto idx = findIndex(key);
			if (idx == size_t.max) return default_value;
			return m_table[idx].value;
		}
	}

	void clear()
	{
		makeUnique();
		foreach (i; 0 .. m_table.length)
			if (!Traits.equals(m_table[i].key, Traits.clearValue)) {
				m_table[i].key = Traits.clearValue;
				m_table[i].value = Value.init;
			}
		m_length = 0;
	}

	void reserve(size_t amount)
	{
		grow(amount);
	}

	void opIndexAssign(T)(T value, Key key)
	{
		import std.algorithm.mutation : move;

		assert(!Traits.equals(key, Traits.clearValue), "Inserting clear value into hash map.");
		grow(1);
		auto i = findInsertIndex(key);
		if (!Traits.equals(m_table[i].key, key)) m_length++;
		m_table[i].key = () @trusted { return cast(UnConst!Key)key; } ();
		m_table[i].value = value;
	}

	ref inout(Value) opIndex(Key key)
	inout {
		auto idx = findIndex(key);
		assert (idx != size_t.max, "Accessing non-existent key.");
		return m_table[idx].value;
	}

	inout(Value)* opBinaryRight(string op)(Key key)
	inout if (op == "in") {
		auto idx = findIndex(key);
		if (idx == size_t.max) return null;
		return &m_table[idx].value;
	}

	int opApply(DG)(scope DG del) if (isOpApplyDg!(DG, Key, Value))
	{
		import std.traits : arity;
		foreach (i; 0 .. m_table.length)
			if (!Traits.equals(m_table[i].key, Traits.clearValue)) {
				static assert(arity!del >= 1 && arity!del <= 2,
						  "isOpApplyDg should have prevented this");
				static if (arity!del == 1) {
					if (int ret = del(m_table[i].value))
						return ret;
				} else
					if (int ret = del(m_table[i].key, m_table[i].value))
						return ret;
			}
		return 0;
	}

	auto byKey() { return bySlot.map!((ref e) => e.key); }
	auto byKey() const { return bySlot.map!((ref e) => e.key); }
	auto byValue() { return bySlot.map!(ref(ref e) => e.value); }
	auto byValue() const { return bySlot.map!(ref(ref e) => e.value); }
	auto byKeyValue() { import std.typecons : Tuple; return bySlot.map!((ref e) => Tuple!(Key, "key", Value, "value")(e.key, e.value)); }
	auto byKeyValue() const { import std.typecons : Tuple; return bySlot.map!((ref e) => Tuple!(const(Key), "key", const(Value), "value")(e.key, e.value)); }

	private auto bySlot() { return m_table[].filter!((ref e) => !Traits.equals(e.key, Traits.clearValue)); }
	private auto bySlot() const { return m_table[].filter!((ref e) => !Traits.equals(e.key, Traits.clearValue)); }

	private size_t findIndex(Key key)
	const {
		if (m_length == 0) return size_t.max;
		size_t start = Traits.hashOf(key) & (m_table.length-1);
		auto i = start;
		while (!Traits.equals(m_table[i].key, key)) {
			if (Traits.equals(m_table[i].key, Traits.clearValue)) return size_t.max;
			if (++i >= m_table.length) i -= m_table.length;
			if (i == start) return size_t.max;
		}
		return i;
	}

	private size_t findInsertIndex(Key key)
	const {
		auto hash = Traits.hashOf(key);
		size_t target = hash & (m_table.length-1);
		auto i = target;
		while (!Traits.equals(m_table[i].key, Traits.clearValue) && !Traits.equals(m_table[i].key, key)) {
			if (++i >= m_table.length) i -= m_table.length;
			assert (i != target, "No free bucket found, HashMap full!?");
		}
		return i;
	}

	private void grow(size_t amount)
	@safe {
		auto newsize = m_length + amount;
		if (newsize < (m_table.length*2)/3) {
			makeUnique();
			return;
		}
		auto newcap = m_table.length ? m_table.length : 16;
		while (newsize >= (newcap*2)/3) newcap *= 2;
		resize(newcap);
	}

	private void makeUnique()
	@trusted {
		if (m_table.isUnique) return;

		m_table = m_table.dup;
	}

	private void resize(size_t new_size)
	@trusted {
		assert(!m_resizing);
		m_resizing = true;
		scope(exit) m_resizing = false;

		uint pot = 0;
		while (new_size > 1) {
			pot++;
			new_size /= 2;
		}
		new_size = 1 << pot;

		auto oldtable = m_table;

		// allocate the new array, automatically initializes with empty entries (Traits.clearValue)
		m_table = m_table.createNew(new_size);

			// perform a move operation of all non-empty elements from the old array to the new one
		foreach (ref el; oldtable)
				if (!Traits.equals(el.key, Traits.clearValue)) {
				auto idx = findInsertIndex(el.key);
				(cast(ubyte[])(&m_table[idx])[0 .. 1])[] = (cast(ubyte[])(&el)[0 .. 1])[];
			}

		// free the old table without calling destructors
		if (oldtable.isUnique)
			oldtable.deallocate();
	}
}

nothrow unittest {
	import std.conv;

	HashMap!(string, string) map;

	foreach (i; 0 .. 100) {
		map[to!string(i)] = to!string(i) ~ "+";
		assert(map.length == i+1);
	}

	foreach (i; 0 .. 100) {
		auto str = to!string(i);
		auto pe = str in map;
		assert(pe !is null && *pe == str ~ "+");
		assert(map[str] == str ~ "+");
	}

	foreach (i; 0 .. 50) {
		map.remove(to!string(i));
		assert(map.length == 100-i-1);
	}

	foreach (i; 50 .. 100) {
		auto str = to!string(i);
		auto pe = str in map;
		assert(pe !is null && *pe == str ~ "+");
		assert(map[str] == str ~ "+");
	}
}

// test for nothrow/@nogc compliance
nothrow unittest {
	HashMap!(int, int) map1;
	HashMap!(string, string) map2;
	map1[1] = 2;
	map2["1"] = "2";

	@nogc nothrow void performNoGCOps()
	{
		foreach (int v; map1) {}
		foreach (int k, int v; map1) {}
		assert(1 in map1);
		assert(map1.length == 1);
		assert(map1[1] == 2);
		assert(map1.getNothrow(1, -1) == 2);

		foreach (string v; map2) {}
		foreach (string k, string v; map2) {}
		assert("1" in map2);
		assert(map2.length == 1);
		assert(map2["1"] == "2");
		assert(map2.getNothrow("1", "") == "2");
	}

	performNoGCOps();
}

unittest { // test for proper use of constructor/post-blit/destructor
	static struct Test {
		static size_t constructedCounter = 0;
		bool constructed = false;
		this(int) { constructed = true; constructedCounter++; }
		this(this) nothrow { if (constructed) constructedCounter++; }
		~this() nothrow { if (constructed) constructedCounter--; }
	}

	assert(Test.constructedCounter == 0);

	{ // sanity check
		Test t;
		assert(Test.constructedCounter == 0);
		t = Test(1);
		assert(Test.constructedCounter == 1);
		auto u = t;
		assert(Test.constructedCounter == 2);
		t = Test.init;
		assert(Test.constructedCounter == 1);
	}
	assert(Test.constructedCounter == 0);

	{ // basic insertion and hash map resizing
		HashMap!(int, Test) map;
		foreach (i; 1 .. 67) {
			map[i] = Test(1);
			assert(Test.constructedCounter == i);
		}
	}

	assert(Test.constructedCounter == 0);

	{ // test clear() and overwriting existing entries
		HashMap!(int, Test) map;
		foreach (i; 1 .. 67) {
			map[i] = Test(1);
			assert(Test.constructedCounter == i);
		}
		map.clear();
		foreach (i; 1 .. 67) {
			map[i] = Test(1);
			assert(Test.constructedCounter == i);
		}
		foreach (i; 1 .. 67) {
			map[i] = Test(1);
			assert(Test.constructedCounter == 66);
		}
	}

	assert(Test.constructedCounter == 0);

	{ // test removing entries and adding entries after remove
		HashMap!(int, Test) map;
		foreach (i; 1 .. 67) {
			map[i] = Test(1);
			assert(Test.constructedCounter == i);
		}
		foreach (i; 1 .. 33) {
			map.remove(i);
			assert(Test.constructedCounter == 66 - i);
		}
		foreach (i; 67 .. 130) {
			map[i] = Test(1);
			assert(Test.constructedCounter == i - 32);
		}
	}

	assert(Test.constructedCounter == 0);
}

unittest { // large alignment test;
	align(32) static struct S { int i; }

	HashMap!(int, S)[] amaps;
	 // NOTE: forcing new allocations to increase the likelyhood of getting a misaligned allocation from the GC
	foreach (i; 0 .. 100) {
		HashMap!(int, S) a;
		a[1] = S(42);
		a[2] = S(43);
		assert(a[1] == S(42));
		assert(a[2] == S(43));
		assert(cast(size_t)cast(void*)&a[1] % S.alignof == 0);
		assert(cast(size_t)cast(void*)&a[2] % S.alignof == 0);
		amaps ~= a;
	}

	HashMap!(S, int)[] bmaps;
	foreach (i; 0 .. 100) {
		HashMap!(S, int) b;
		b[S(1)] = 42;
		b[S(2)] = 43;
		assert(b[S(1)] == 42);
		assert(b[S(2)] == 43);
		assert(cast(size_t)cast(void*)&b[S(1)] % S.alignof == 0);
		assert(cast(size_t)cast(void*)&b[S(2)] % S.alignof == 0);
		bmaps ~= b;
	}
}

private template UnConst(T) {
	static if (is(T U == const(U))) {
		alias UnConst = U;
	} else static if (is(T V == immutable(V))) {
		alias UnConst = V;
	} else alias UnConst = T;
}
