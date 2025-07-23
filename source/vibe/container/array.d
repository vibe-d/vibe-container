module vibe.container.array;

import vibe.container.internal.rctable;
import vibe.container.internal.utilallocator;

import std.algorithm.comparison : max;
import std.algorithm.mutation : swap;


/** Represents a deterministically allocated array type.

	The underlying buffer is allocated in powers of two and uses copy-on-write
	to enable value semantics without requiring to copy data when passing
	copies of the array around.
*/
struct Array(T, Allocator = GCAllocator)
{
	private {
		alias Table = RCTable!(T, Allocator);
		Table m_table;
		size_t m_length;
	}

	static if (!is(typeof(Allocator.instance))) {
		this(Allocator allocator)
		{
			m_table = Table(allocator);
		}
	}


	/// Determines whether the array is currently empty.
	bool empty() const { return m_length == 0; }

	/** The current number of elements.

		Note that reducing the length of a array will not free the underlying
		buffer, but instead will only make use of a smaller portion. This
		enables increasing the length later without having to re-allocate.
	*/
	size_t length() const { return m_length; }
	/// ditto
	void length(size_t count)
	@safe {
		if (count == m_length) return;

		if (count <= m_table.length) {
			if (count < m_length) {
				if (() @trusted { return !m_table.isUnique(); } ()) {
					auto new_table = () @trusted { return m_table.createNew(allocationCount(count)); } ();
					new_table[0 .. count] = m_table[0 .. count];
					swap(m_table, new_table);
				} else m_table[count .. m_length] = T.init;
			}
		} else {
			auto new_table = () @trusted { return m_table.createNew(allocationCount(count)); } ();
			new_table[0 .. m_length] = m_table[0 .. m_length];
			swap(m_table, new_table);
		}

		assert(count <= m_table.length, "Resized table not large enough for requested length!?");
		m_length = count;
	}

	/// Appends elements to the end of the array
	void insertBack(T element)
	{
		makeUnique();
		auto idx = m_length;
		length = idx + 1;
		swap(m_table[idx], element);
	}
	/// ditto
	void insertBack(T[] elements)
	{
		if (elements.length == 0) return;

		makeUnique();
		auto idx = m_length;
		length = idx + elements.length;
		foreach (i, ref el; elements)
			m_table[idx + i] = el;
	}
	/// ditto
	void opOpAssign(string op = "~")(T element) { insertBack(element); }
	/// ditto
	void opOpAssign(string op = "~")(T[] elements) { insertBack(elements); }

	static if (is(typeof((const T x) { T y; y = x; }))) {
		/// ditto
		void insertBack(const(T)[] elements) {
			if (elements.length == 0) return;

			makeUnique();
			auto idx = m_length;
			length = idx + elements.length;
			foreach (i, ref el; elements)
				m_table[idx + i] = el;
		}
		/// ditto
		void opOpAssign(string op = "~")(const(T)[] elements) { insertBack(elements); }
	}

	/// Removes the last element of the array
	void removeBack()
	{
		assert(length >= 1, "Attempt to remove element from empty array");
		length = length - 1;
	}

	/** Accesses the element at the given index.

		Note that accessing an alement of a non-const array will trigger the
		copy-on-write logic and may allocate, whereas accessing an element of
		a `const` array will not.
	*/
	ref const(T) opIndex(size_t index) const return { return m_table[index]; }
	/// ditto
	ref T opIndex(size_t index) return { makeUnique(); return m_table[index]; }

	/** Accesses a slice of elements.

		Note that accessing an alement of a non-const array will trigger the
		copy-on-write logic and may allocate, whereas accessing an element of
		a `const` array will not.
	*/
	const(T)[] opSlice(size_t from, size_t to) const return { return m_table[from .. to]; }
	/// ditto
	T[] opSlice(size_t from, size_t to) return { makeUnique(); return m_table[from .. to]; }

	/** Returns a slice of all elements of the array.

		Note that accessing an alement of a non-const array will trigger the
		copy-on-write logic and may allocate, whereas accessing an element of
		a `const` array will not.
	*/
	const(T)[] opSlice() const return { return m_table[0 .. length]; }
	/// ditto
	T[] opSlice() return { makeUnique(); return m_table[0 .. length]; }

	static size_t allocationCount(size_t count)
	{
		return nextPOT(max(count, 16, 1024/T.sizeof));
	}

	private void makeUnique()
	@trusted {
		if (!m_table.isUnique())
			m_table = m_table.dup;
	}
}


@safe nothrow unittest {
	Array!int v;
	assert(v.length == 0);
	v.length = 1;
	assert(v.length == 1);
	assert(v[0] == 0);
	v[0] = 2;
	assert(v[0] == 2);
	v ~= 3;
	assert(v.length == 2);
	assert(v[1] == 3);

	const w = v;
	assert(w.length == 2);
	assert(w[] == [2, 3]);
	assert(w[].ptr is (cast(const)v)[].ptr);

	v.length = 3;
	assert(v.length == 3);
	assert(w.length == 2);
	assert(w[].ptr is (cast(const)v)[].ptr);

	v[0] = 2;
	assert(w[].ptr !is (cast(const)v)[].ptr);
	assert(w[0] == 2);
}

private size_t nextPOT(size_t n) @safe nothrow @nogc
{
	foreach_reverse (i; 0 .. size_t.sizeof*8) {
		size_t ni = cast(size_t)1 << i;
		if (n & ni) {
			return n & (ni-1) ? ni << 1 : ni;
		}
	}
	return 1;
}

unittest {
	assert(nextPOT(1) == 1);
	assert(nextPOT(2) == 2);
	assert(nextPOT(3) == 4);
	assert(nextPOT(4) == 4);
	assert(nextPOT(5) == 8);
}
