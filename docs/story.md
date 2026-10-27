# The long version

*Written for a post about this repo. The short version is in the README.*

Microsoft Lens was a really good app for quickly scanning documents on a phone. It was my go-to for
anything I needed to keep. That was all before Microsoft decided to move the functionality into
OneDrive and shove OneDrive at us. I kept using an older version while actively checking for
alternatives. Some were worse: they wanted an account on their service, or a subscription before
they would export more than five pages to PDF, or they were drowning in ads. It has been on the
backburner to build something of my own — something I can keep for myself without worrying about
anyone else's decisions. I even built another version of it once, which was kind of fine.

Over the last weekend I was experimenting with REA (Reverse Engineer Anything) and wanted to see if
I could reimagine a version of Lens that I could call my own. Three days and about $3 of tokens
later, I have a working version of the app I call **Scan**. It does one job: scan pages, export them
as images and PDFs, without any of the other hassle.

Would I say I made something Microsoft took years to perfect in three days? No. Honestly, working on
it made me value what that team did more. How smooth and hassle-free the end-to-end flow was is
something I admired in Lens, missed in the alternatives, and badly wanted to replicate. The corner
detection that keeps up with your hand, the shutter that fires at the right moment, the fact that
you never had to think about where a page went.

And can I say I was completely hands off — typed a prompt, went to watch a movie, and it built
itself? No. I had to watch it and stop it when it went off track:

- When it came to edge detection, the agent started building a brightness-comparison approach from
  scratch. I stopped it and said no: use a TensorFlow edge detection model, and here is the actual
  open-source model and how to use it. Without that it would not have worked properly.
- When it started adding functionality to every screen, I stopped it again: that is not needed. Keep
  it to this specific set of features.
- Every time it reached for a dependency, the question was whether Android or ML Kit already had it.

So what do I think I actually got out of this?

The gap to making something is much smaller than it was. I used to hold off, saying I did not have
time to learn the technology fully and then implement it the way I imagined, and it kept piling up.
Now, instead of typing things line by line, I can hand the coding to the model and spend my attention
on the bigger decisions — how something should be implemented at a higher level, and what it should
feel like.

And if a company decides to sunset a great product in favour of something else, I do not have to
live with that decision. I can build the thing that fits, at a level I control.

Adios. Until we meet next time.
