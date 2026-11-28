// Checks the PositionSlop option of 0002-contacts-Add-a-position-slop-for-new-contacts.patch.

#include <contacts/contact.hpp>
#include <contacts/stability/stabilizer.hpp>

#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace iptsd;
using contacts::Contact;
using contacts::stability::Config;
using contacts::stability::Stabilizer;

static int failures = 0;

static Contact<f64> at(usize index, f64 x, f64 y)
{
	Contact<f64> contact {};
	contact.index = index;
	contact.mean = Vector2<f64> {x, y};
	return contact;
}

static Vector2<f64> step(Stabilizer<f64> &stabilizer, Contact<f64> contact)
{
	std::vector<Contact<f64>> frame {contact};
	stabilizer.stabilize(frame);
	return frame[0].mean;
}

static void lift(Stabilizer<f64> &stabilizer)
{
	std::vector<Contact<f64>> frame {};
	stabilizer.stabilize(frame);
}

static void expect(bool ok, const char *what)
{
	if (!ok) {
		std::fprintf(stderr, "not ok - %s\n", what);
		failures++;
	}
}

static bool is(const Vector2<f64> &p, f64 x, f64 y)
{
	return (p - Vector2<f64> {x, y}).norm() < 1e-9;
}

int main()
{
	Config<f64> config {};
	config.position_slop = Vector2<f64> {0.02, 0.02};

	{
		Stabilizer<f64> stabilizer {Config<f64> {}};
		step(stabilizer, at(0, 0.5, 0.5));
		expect(is(step(stabilizer, at(0, 0.51, 0.5)), 0.51, 0.5),
		       "without PositionSlop a contact moves as before");
	}

	{
		Stabilizer<f64> stabilizer {config};
		step(stabilizer, at(0, 0.5, 0.5));
		expect(is(step(stabilizer, at(0, 0.51, 0.5)), 0.5, 0.5),
		       "a new contact stays where it appeared while inside the slop");
		expect(is(step(stabilizer, at(0, 0.5, 0.515)), 0.5, 0.5),
		       "the slop is measured from where the contact appeared");
	}

	{
		Stabilizer<f64> stabilizer {config};
		step(stabilizer, at(0, 0.5, 0.5));
		expect(is(step(stabilizer, at(0, 0.53, 0.5)), 0.53, 0.5),
		       "a contact that leaves the slop follows the finger");
		expect(is(step(stabilizer, at(0, 0.535, 0.5)), 0.535, 0.5),
		       "a contact that has left the slop is not held again");
		expect(is(step(stabilizer, at(0, 0.51, 0.5)), 0.51, 0.5),
		       "a contact that comes back near where it appeared still follows the finger");
	}

	{
		Stabilizer<f64> stabilizer {config};
		step(stabilizer, at(0, 0.5, 0.5));
		lift(stabilizer);
		step(stabilizer, at(0, 0.2, 0.2));
		expect(is(step(stabilizer, at(0, 0.21, 0.2)), 0.2, 0.2),
		       "a lifted contact's index is anchored again where the next contact appears");
	}

	if (failures == 0)
		std::puts("ok - PositionSlop holds new contacts until they leave the slop");

	return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
