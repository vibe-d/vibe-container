/**
	Multi hash map implementation.

	Copyright: © 2013-2025 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.container.multihashmap;

import vibe.container.internal.rctable;
import vibe.container.internal.utilallocator;

import std.conv : emplace;
import std.range : Take;
import std.traits;

public import vibe.container.hashmap : DefaultHashMapTraits;


/** Implements a hash based multi-map with linear probing.

	Insertion of multiple elements with the same key is possible. All such
	duplicate elements can be queried using `equalRange`.
*/
struct MultiHashMap(TKey, TValue, Traits = DefaultHashMapTraits!TKey, Allocator = IAllocator)
{
@safe:
	import vibe.container.internal.traits : isOpApplyDg;
	import std.algorithm.iteration : map;
	import std.algorithm.mutation : moveEmplace;
	import std.typecons : Tuple;

	alias Key = TKey;
	alias Value = TValue;

	struct TableEntry {
		UnConst!Key key = Traits.clearValue;
		Value value;

		this(Key key, Value value) @trusted { this.key = cast(UnConst!Key)key; this.value = value; }
	}

	alias Table = RCTable!(TableEntry, Allocator);

	private {
		Table m_table; // NOTE: capacity is always POT
		size_t m_length;
		bool m_resizing;
	}

	static if (!is(typeof(Allocator.instance))) {
		this(Allocator allocator)
		{
			m_table = Table(allocator);
		}
	}

	/// Returns the total number of elements, including duplicates.
	@property size_t length() const { return m_length; }

	@property auto byKey() inout { return byEntry.map!(e => e.key); }
	@property auto byValue() inout { return byEntry.map!(e => e.value); }
	@property auto byKeyValue() { return byEntry.map!(e => Tuple!(Key, "key", Value, "value")(e.key, e.value)); }
	@property auto byKeyValue() const { return byEntry.map!(e => Tuple!(const(Key), "key", const(Value), "value")(e.key, e.value)); }

	/** Removes all elements of the given range.

		Note that the second overload allows to limit the number of removed
		elements using `std.range.take`.
	*/
	void remove(EqualRange!TableEntry range)
	{
		doRemove(range);
	}
	/// ditto
	void remove(Take!(EqualRange!TableEntry) range)
	{
		doRemove(range.source, range.maxLength);
	}

	/** Removes all elements with the given key.
	*/
	void removeAll(Key key)
	{
		remove(equalRange(key));
	}

	/** Returns a range of all elements with the given key.
	*/
	EqualRange!TableEntry equalRange(Key key)
	{
		assert(!Traits.equals(key, Traits.clearValue));
		auto idx = findIndex(key);
		if (idx != size_t.max) return EqualRange!TableEntry(m_table.get, idx, idx);
		else return EqualRange!TableEntry(null, size_t.max, size_t.max);
	}
	/// ditto
	EqualRange!(const(TableEntry)) equalRange(Key key)
	const {
		assert(!Traits.equals(key, Traits.clearValue));
		auto idx = findIndex(key);
		if (idx != size_t.max) return EqualRange!(const(TableEntry))(m_table.get, idx, idx);
		else return EqualRange!(const(TableEntry))(null, size_t.max, size_t.max);
	}

	/** Removes all elements from the map.
	*/
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

	/** Inserts a an element into the map.

		Note that duplicates will be inserted at the back of the range of
		elements with equal keys.
	*/
	void insert(Key key, Value value)
	{
		assert(!Traits.equals(key, Traits.clearValue), "Inserting clear value into hash map.");
		grow(1);
		auto i = findInsertIndex(key);
		m_length++;
		m_table[i] = TableEntry(key, value);
	}

	/// Tests whether any elements with the given key exist in the map.
	bool opBinaryRight(string op : "in")(Key key) const { return !equalRange(key).empty; }

	/** Iterates over all elements in the map.
	*/
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

	static struct EqualRange(TE) {
		private {
			TE[] m_table;
			size_t m_startIndex;
			size_t m_index;
		}

		@property EqualRange save() { return this; }

		@property bool empty() const { return m_index == size_t.max; }
		@property ref front()
		inout {
			assert(!empty, "Accessing empty MultiHashMap.EqualRange");
			assert(!Traits.equals(m_table[m_index].key, Traits.clearValue), "EqualRange contains clear value!? Concurrently modified map?");
			return m_table[m_index].value;
		}

		void popFront()
		{
			assert(!empty, "Popping from empty MultiHashMap.EqualRange");
			auto key = m_table[m_startIndex].key;
			assert(!Traits.equals(key, Traits.clearValue), "EqualRange starts with clear value!? Concurrently modified map?");

			do {
				m_index = (m_index + 1) & (m_table.length - 1);

				if (m_index == m_startIndex ||
					Traits.equals(m_table[m_index].key, Traits.clearValue))
				{
					m_index = size_t.max;
					return;
				}
			} while (!Traits.equals(m_table[m_index].key, key));
		}
	}

	private void doRemove(EqualRange!TableEntry range, size_t limit = size_t.max)
	{
		if (range.empty) return;

		makeUnique();

		auto key = m_table[range.m_index].key;
		auto cidx = Traits.hashOf(key) & (m_table.length - 1);
		auto idx = range.m_index;

		// remove elements until either the limit is reached, or no more
		// elements with the same key exist within the range
		while (true) {
			if (limit-- == 0) return;
			m_length--;

			auto i = idx;
			shift_loop:
			while (true) {
				m_table[i].key = Traits.clearValue;
				m_table[i].value = Value.init;

				size_t j = i, r;
				do {
					i = (i + 1) & (m_table.length - 1);
					if (Traits.equals(m_table[i].key, Traits.clearValue))
						break shift_loop;
					r = Traits.hashOf(m_table[i].key) & (m_table.length-1);
				} while ((j<r && r<=i) || (i<j && j<r) || (r<=i && i<j));
				m_table[j] = m_table[i];
			}

			// find the next element of the equal range
			while (!Traits.equals(m_table[idx].key, key)) {
				if (Traits.equals(m_table[idx].key, Traits.clearValue))
					return;
				idx = (idx + 1) & (m_table.length - 1);
				// make sure that no elements preceding range.m_index get
				// removed
				if (idx == range.m_startIndex)
					return;
			}
		}
	}


	private size_t findIndex(Key key)
	const {
		if (m_length == 0) return size_t.max;
		size_t start = Traits.hashOf(key) & (m_table.length-1);
		auto i = start;
		while (!Traits.equals(m_table[i].key, key)) {
			if (Traits.equals(m_table[i].key, Traits.clearValue)) return size_t.max;
			i = (i + 1) & (m_table.length - 1);
			if (i == start) return size_t.max;
		}
		return i;
	}

	private size_t findInsertIndex(Key key)
	const {
		auto hash = Traits.hashOf(key);
		size_t target = hash & (m_table.length-1);
		auto i = target;
		while (!Traits.equals(m_table[i].key, Traits.clearValue)) {
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
		assert(1 << pot >= new_size);
		new_size = 1 << pot;

		auto oldtable = m_table;

		// allocate the new array, automatically initializes with empty entries (Traits.clearValue)
		m_table = m_table.createNew(new_size);

		if (oldtable.isUnique) {
			// perform a move operation of all non-empty elements from the old array to the new one
			size_t cnt = 0;
			foreach (ref el; oldtable)
				if (!Traits.equals(el.key, Traits.clearValue)) {
					auto idx = findInsertIndex(el.key);
					moveEmplace(el, m_table[idx]);
					cnt++;
				}
			assert(cnt == m_length);
			if (m_length == 0)
				foreach (ref el; m_table)
					assert(el == TableEntry.init);

			// free the old table without calling destructors
			oldtable.deallocate();
		} else {
			// perform a copy operation of all non-empty elements from the old array to the new one
			foreach (ref el; oldtable)
				if (!Traits.equals(el.key, Traits.clearValue)) {
					auto idx = findInsertIndex(el.key);
					m_table[idx] = el;
				}
		}
	}

	EntryRange!TableEntry byEntry() { return EntryRange!TableEntry(m_table.get, 0); }
	EntryRange!(const(TableEntry)) byEntry() const { return EntryRange!(const(TableEntry))(m_table.get, 0); }

	private static struct EntryRange(TE) {
		private {
			TE[] m_table;
			size_t m_index;
		}

		this(TE[] table, size_t start_index)
		{
			m_table = table;
			m_index = start_index - 1;
			popFront(); // find the first non-empty entry
		}

		@property bool empty() const { return m_index >= m_table.length || Traits.equals(m_table[m_index].key, Traits.clearValue); }
		@property ref front() inout { return m_table[m_index]; }

		void popFront()
		{
			do m_index++;
			while (m_index < m_table.length && Traits.equals(m_table[m_index].key, Traits.clearValue));
		}
	}
}

unittest { // singular tests
	import std.algorithm.comparison : equal;
	import std.conv : to;

	MultiHashMap!(string, string) map;

	foreach (i; 0 .. 100) {
		map.insert(to!string(i), to!string(i) ~ "+");
		assert(map.length == i+1);
	}

	foreach (i; 0 .. 100) {
		auto str = to!string(i);
		assert(str in map);
		assert(map.equalRange(str).equal([str ~ "+"]));
	}

	foreach (i; 0 .. 50) {
		map.remove(map.equalRange(to!string(i)));
		assert(map.length == 100-i-1);
	}

	foreach (i; 50 .. 100) {
		auto str = to!string(i);
		auto pe = str in map;
		assert(pe);
		assert(map.equalRange(str).equal([str ~ "+"]));
	}
}

unittest { // basic multi tests
	import std.range : only, take;
	import std.algorithm.comparison : equal;

	MultiHashMap!(int, int) map;
	map.insert(1, 2);
	map.insert(2, 4);
	map.insert(1, 5);
	map.insert(1, 6);
	assert(map.length == 4);
	assert(map.equalRange(1).equal(only(2, 5, 6)));
	assert(map.equalRange(2).equal(only(4)));
	import std.conv;
	assert(map.byKey.equal(only(1, 2, 1, 1)), map.byKey.to!string);
	assert(map.byValue.equal(only(2, 4, 5, 6)));

	map.remove(map.equalRange(1).take(1));
	assert(map.length == 3);
	assert(map.equalRange(1).equal(only(5, 6)));
	assert(map.equalRange(2).equal(only(4)));

	map.remove(map.equalRange(1));
	assert(map.length == 1);
	assert(map.equalRange(1).empty);
	assert(map.equalRange(2).equal(only(4)));

	map.remove(map.equalRange(2));
	assert(map.length == 0);

	// test limited removal of elements that wrap around the table end
	// (the initial table size is 16)
	map.insert(14, 1);
	map.insert(14, 2);
	map.insert(14, 3);
	map.insert(14, 4);
	assert(map.length == 4);
	assert(map.equalRange(14).equal(only(1, 2, 3, 4)));

	auto r = map.equalRange(14);
	r.popFront();
	map.remove(r.take(2));
	assert(map.length == 2);
	assert(map.equalRange(14).equal(only(1, 4)));
}

// test for nothrow/@nogc compliance
nothrow unittest {
	import std.algorithm.comparison : equal;
	import std.range : only;

	MultiHashMap!(int, int, DefaultHashMapTraits!int, Mallocator) map1;
	MultiHashMap!(string, string, DefaultHashMapTraits!string, Mallocator) map2;
	map1.insert(1, 2);
	map2.insert("1", "2");

	@nogc nothrow void performNoGCOps()
	{
		foreach (int v; map1) {}
		foreach (int k, int v; map1) {}
		assert(1 in map1);
		assert(map1.length == 1);
		assert(map1.equalRange(1).equal(only(2)));

		foreach (string v; map2) {}
		foreach (string k, string v; map2) {}
		assert("1" in map2);
		assert(map2.length == 1);
		assert(map2.equalRange("1").equal(only("2")));
	}

	performNoGCOps();
}

@safe unittest { // test for proper use of constructor/post-blit/destructor
	static struct Test {
		@safe nothrow:
		static size_t constructedCounter = 0;
		bool constructed = false;
		this(int) { constructed = true; constructedCounter++; }
		this(this) { if (constructed) constructedCounter++; }
		~this() { if (constructed) constructedCounter--; }
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
		MultiHashMap!(int, Test) map;
		foreach (i; 1 .. 67) {
			map.insert(i, Test(1));
			assert(Test.constructedCounter == i);
		}
	}

	assert(Test.constructedCounter == 0);

	{ // test clear() and overwriting existing entries
		MultiHashMap!(int, Test) map;
		foreach (i; 1 .. 67) {
			map.insert(i, Test(1));
			assert(Test.constructedCounter == i);
		}
		assert(Test.constructedCounter == 66);
		map.clear();
		assert(Test.constructedCounter == 0);
		foreach (i; 1 .. 67) {
			map.insert(i, Test(1));
			assert(Test.constructedCounter == i);
		}
		assert(Test.constructedCounter == 66);
		foreach (i; 1 .. 67) {
			map.removeAll(i);
			assert(Test.constructedCounter == 65);
			map.insert(i, Test(1));
			assert(Test.constructedCounter == 66);
		}
	}

	assert(Test.constructedCounter == 0);

	{ // test removing entries and adding entries after remove
		MultiHashMap!(int, Test) map;
		foreach (i; 1 .. 67) {
			map.insert(i, Test(1));
			assert(Test.constructedCounter == i);
		}
		foreach (i; 1 .. 33) {
			map.remove(map.equalRange(i));
			assert(Test.constructedCounter == 66 - i);
		}
		foreach (i; 67 .. 130) {
			map.insert(i, Test(1));
			assert(Test.constructedCounter == i - 32);
		}
	}

	assert(Test.constructedCounter == 0);
}

private template UnConst(T) {
	static if (is(T U == const(U))) {
		alias UnConst = U;
	} else static if (is(T V == immutable(V))) {
		alias UnConst = V;
	} else alias UnConst = T;
}
